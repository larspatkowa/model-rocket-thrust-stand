#include <Arduino.h>
#include <BluetoothSerial.h>
#include <SPI.h>
#include <WiFi.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <cstring>

namespace Pins {
constexpr uint8_t SCLK = 18;
constexpr uint8_t MISO = 19;
constexpr uint8_t MOSI = 23;
constexpr uint8_t CS = 25;
constexpr uint8_t DRDY = 27;
}

namespace Ads1220Command {
constexpr uint8_t RESET = 0x06;
constexpr uint8_t START = 0x08;
constexpr uint8_t RDATA = 0x10;
}

namespace Ads1220Config {
// Register 1 DR[2:0] = 110b: 1000 SPS in normal mode.
constexpr uint8_t DATA_RATE_REGISTER = 0xC4;
constexpr uint16_t NOMINAL_RATE_HZ = 1000;
}

namespace CaptureConfig {
enum class WirelessMode {
    BLUETOOTH,
    WIFI
};

constexpr uint32_t SERIAL_BAUD = 460800;
constexpr uint16_t WIFI_PORT = 9100;
constexpr char AP_PASSWORD[] = "thruststand";
constexpr char BLUETOOTH_PIN[] = "3300";
constexpr WirelessMode WIRELESS_MODE = WirelessMode::BLUETOOTH;
constexpr size_t SAMPLE_BUFFER_CAPACITY = 8192;
constexpr size_t SAMPLES_PER_PACKET = 32;
constexpr size_t PACKETS_PER_TRANSPORT_PASS = 4;
}

namespace Protocol {
constexpr uint32_t MAGIC = 0x3253544D;  // "MTS2" on the wire.
constexpr uint8_t VERSION = 2;

struct __attribute__((packed)) PacketHeader {
    uint32_t magic;
    uint8_t version;
    uint8_t flags;
    uint16_t headerSize;
    uint16_t packetSize;
    uint16_t sampleCount;
    uint32_t bootId;
    uint32_t startSequence;
    uint64_t baseTimeUs;
};

struct __attribute__((packed)) SampleDelta {
    uint32_t timeDeltaUs;
    int32_t raw;
};

struct __attribute__((packed)) SamplePacket {
    PacketHeader header;
    SampleDelta samples[CaptureConfig::SAMPLES_PER_PACKET];
    uint32_t crc32;
};

static_assert(sizeof(PacketHeader) == 28, "Unexpected packet-header size");
static_assert(sizeof(SampleDelta) == 8, "Unexpected sample-delta size");
static_assert(sizeof(SamplePacket) == 288, "Unexpected maximum packet size");
}

struct __attribute__((packed)) CapturedSample {
    uint32_t deviceTimeUsLow;
    int32_t raw;
};

static_assert(sizeof(CapturedSample) == 8, "Unexpected captured-sample size");

SPISettings adsSpiSettings(1000000UL, MSBFIRST, SPI_MODE1);
BluetoothSerial SerialBT;
WiFiServer sampleServer(CaptureConfig::WIFI_PORT);
WiFiClient sampleClient;

CapturedSample sampleBuffer[CaptureConfig::SAMPLE_BUFFER_CAPACITY];
portMUX_TYPE sampleBufferMux = portMUX_INITIALIZER_UNLOCKED;
size_t sampleBufferStart = 0;
size_t sampleBufferCount = 0;
uint32_t sampleBufferOldestSequence = 0;
uint32_t bootId = 0;
uint32_t nextSequence = 0;
char accessPointSsid[32] = {};
char bluetoothName[32] = {};

uint32_t calculateCrc32(const uint8_t* data, size_t length) {
    uint32_t crc = 0xFFFFFFFFUL;

    for (size_t index = 0; index < length; ++index) {
        crc ^= data[index];
        for (uint8_t bit = 0; bit < 8; ++bit) {
            const uint32_t mask = -(crc & 1UL);
            crc = (crc >> 1) ^ (0xEDB88320UL & mask);
        }
    }

    return ~crc;
}

void beginTransaction() {
    SPI.beginTransaction(adsSpiSettings);
    digitalWrite(Pins::CS, LOW);
    delayMicroseconds(2);
}

void endTransaction() {
    delayMicroseconds(2);
    digitalWrite(Pins::CS, HIGH);
    SPI.endTransaction();
}

void sendCommand(uint8_t command) {
    beginTransaction();
    SPI.transfer(command);
    endTransaction();
}

void writeRegisters() {
    /*
     * Register 0: 0x3E
     * AIN1 positive, AIN2 negative, gain 128, PGA enabled.
     *
     * Register 1: 0xC4
     * 1000 SPS, normal mode, continuous conversions.
     *
     * Register 2: 0x40
     * External reference on REFP0 and REFN0.
     *
     * Register 3: 0x00
     * IDACs disabled and normal DRDY behavior.
     */
    constexpr uint8_t registers[4] = {
        0x3E,
        Ads1220Config::DATA_RATE_REGISTER,
        0x40,
        0x00
    };

    beginTransaction();
    SPI.transfer(0x43);  // WREG register 0, four registers.

    for (uint8_t value : registers) {
        SPI.transfer(value);
    }

    endTransaction();
}

void readRegisters(uint8_t registers[4]) {
    beginTransaction();
    SPI.transfer(0x23);  // RREG register 0, four registers.

    for (size_t index = 0; index < 4; ++index) {
        registers[index] = SPI.transfer(0x00);
    }

    endTransaction();
}

bool waitForDrdyLevel(uint8_t level, uint32_t timeoutMs = 1000) {
    const uint32_t startedAt = millis();

    while (digitalRead(Pins::DRDY) != level) {
        if (millis() - startedAt >= timeoutMs) {
            return false;
        }

        delayMicroseconds(20);
    }

    return true;
}

bool readRawConversion(int32_t& result, uint64_t& readyAtUs) {
    if (!waitForDrdyLevel(LOW)) {
        return false;
    }

    readyAtUs = static_cast<uint64_t>(esp_timer_get_time());
    beginTransaction();
    SPI.transfer(Ads1220Command::RDATA);

    uint32_t raw = static_cast<uint32_t>(SPI.transfer(0x00)) << 16;
    raw |= static_cast<uint32_t>(SPI.transfer(0x00)) << 8;
    raw |= static_cast<uint32_t>(SPI.transfer(0x00));

    endTransaction();

    // Requiring DRDY high prevents duplicate reads in continuous mode.
    if (!waitForDrdyLevel(HIGH)) {
        return false;
    }

    if ((raw & 0x00800000UL) != 0) {
        raw |= 0xFF000000UL;
    }

    result = static_cast<int32_t>(raw);
    return true;
}

void storeSample(const CapturedSample& sample, uint32_t sequence) {
    portENTER_CRITICAL(&sampleBufferMux);

    if (sampleBufferCount < CaptureConfig::SAMPLE_BUFFER_CAPACITY) {
        if (sampleBufferCount == 0) {
            sampleBufferOldestSequence = sequence;
        }
        const size_t index =
            (sampleBufferStart + sampleBufferCount) % CaptureConfig::SAMPLE_BUFFER_CAPACITY;
        sampleBuffer[index] = sample;
        ++sampleBufferCount;
    } else {
        sampleBuffer[sampleBufferStart] = sample;
        sampleBufferStart = (sampleBufferStart + 1) % CaptureConfig::SAMPLE_BUFFER_CAPACITY;
        ++sampleBufferOldestSequence;
    }

    portEXIT_CRITICAL(&sampleBufferMux);
}

size_t copySamplesForSequence(
    uint32_t requestedSequence,
    CapturedSample* samples,
    size_t capacity,
    uint32_t& actualStartSequence
) {
    size_t copied = 0;

    portENTER_CRITICAL(&sampleBufferMux);

    if (sampleBufferCount > 0) {
        const uint32_t newestSequence =
            sampleBufferOldestSequence + static_cast<uint32_t>(sampleBufferCount - 1);
        actualStartSequence = requestedSequence < sampleBufferOldestSequence
            ? sampleBufferOldestSequence
            : requestedSequence;
        if (actualStartSequence <= newestSequence) {
            const size_t offset =
                static_cast<size_t>(actualStartSequence - sampleBufferOldestSequence);
            const size_t available = sampleBufferCount - offset;
            copied = available < capacity ? available : capacity;
            for (size_t index = 0; index < copied; ++index) {
                samples[index] = sampleBuffer[
                    (sampleBufferStart + offset + index) % CaptureConfig::SAMPLE_BUFFER_CAPACITY
                ];
            }
        }
    }

    portEXIT_CRITICAL(&sampleBufferMux);
    return copied;
}

uint32_t oldestBufferedSequence() {
    uint32_t sequence = 0;

    portENTER_CRITICAL(&sampleBufferMux);
    if (sampleBufferCount > 0) {
        sequence = sampleBufferOldestSequence;
    }
    portEXIT_CRITICAL(&sampleBufferMux);

    return sequence;
}

size_t buildPacket(uint32_t requestedSequence, Protocol::SamplePacket& packet) {
    CapturedSample samples[CaptureConfig::SAMPLES_PER_PACKET] = {};
    uint32_t actualStartSequence = requestedSequence;
    const size_t sampleCount = copySamplesForSequence(
        requestedSequence,
        samples,
        CaptureConfig::SAMPLES_PER_PACKET,
        actualStartSequence
    );
    if (sampleCount < CaptureConfig::SAMPLES_PER_PACKET) {
        return 0;
    }

    const uint64_t nowUs = static_cast<uint64_t>(esp_timer_get_time());
    const uint64_t timestampEpoch = nowUs & 0xFFFFFFFF00000000ULL;
    uint64_t baseTimeUs = timestampEpoch | samples[0].deviceTimeUsLow;
    if (baseTimeUs > nowUs && baseTimeUs - nowUs > 0x80000000ULL) {
        baseTimeUs -= 0x100000000ULL;
    } else if (nowUs > baseTimeUs && nowUs - baseTimeUs > 0x80000000ULL) {
        baseTimeUs += 0x100000000ULL;
    }

    packet.header = {
        Protocol::MAGIC,
        Protocol::VERSION,
        0,
        sizeof(Protocol::PacketHeader),
        static_cast<uint16_t>(
            sizeof(Protocol::PacketHeader) +
            sampleCount * sizeof(Protocol::SampleDelta) +
            sizeof(packet.crc32)
        ),
        static_cast<uint16_t>(sampleCount),
        bootId,
        actualStartSequence,
        baseTimeUs
    };

    for (size_t index = 0; index < sampleCount; ++index) {
        packet.samples[index] = {
            static_cast<uint32_t>(
                samples[index].deviceTimeUsLow - samples[0].deviceTimeUsLow
            ),
            samples[index].raw
        };
    }

    const size_t withoutCrc = packet.header.packetSize - sizeof(packet.crc32);
    const uint32_t crc32 = calculateCrc32(
        reinterpret_cast<const uint8_t*>(&packet),
        withoutCrc
    );
    memcpy(reinterpret_cast<uint8_t*>(&packet) + withoutCrc, &crc32, sizeof(crc32));
    return packet.header.packetSize;
}

void networkTask(void*) {
    uint32_t sequenceToSend = 0;

    for (;;) {
        WiFiClient candidate = sampleServer.available();
        if (candidate) {
            if (sampleClient) {
                sampleClient.stop();
            }
            sampleClient = candidate;
            sampleClient.setNoDelay(true);
            sequenceToSend = oldestBufferedSequence();
        }

        if (sampleClient && sampleClient.connected()) {
            for (size_t sent = 0; sent < CaptureConfig::PACKETS_PER_TRANSPORT_PASS; ++sent) {
                Protocol::SamplePacket packet = {};
                const size_t packetSize = buildPacket(sequenceToSend, packet);
                if (packetSize == 0) {
                    break;
                }
                const size_t written = sampleClient.write(
                    reinterpret_cast<const uint8_t*>(&packet),
                    packetSize
                );
                if (written != packetSize) {
                    sampleClient.stop();
                    break;
                }
                sequenceToSend =
                    packet.header.startSequence + packet.header.sampleCount;
            }
        } else if (sampleClient) {
            sampleClient.stop();
        }

        delay(1);
    }
}

void bluetoothTask(void*) {
    uint32_t sequenceToSend = 0;
    bool wasConnected = false;

    for (;;) {
        const bool connected = SerialBT.hasClient();
        if (connected && !wasConnected) {
            sequenceToSend = oldestBufferedSequence();
        }

        if (connected) {
            for (size_t sent = 0; sent < CaptureConfig::PACKETS_PER_TRANSPORT_PASS; ++sent) {
                Protocol::SamplePacket packet = {};
                const size_t packetSize = buildPacket(sequenceToSend, packet);
                if (packetSize == 0) {
                    break;
                }
                const size_t written = SerialBT.write(
                    reinterpret_cast<const uint8_t*>(&packet),
                    packetSize
                );
                if (written != packetSize) {
                    break;
                }
                sequenceToSend =
                    packet.header.startSequence + packet.header.sampleCount;
            }
        }

        wasConnected = connected;
        delay(1);
    }
}

void serialTask(void*) {
    uint32_t sequenceToSend = 0;

    for (;;) {
        for (size_t sent = 0; sent < CaptureConfig::PACKETS_PER_TRANSPORT_PASS; ++sent) {
            Protocol::SamplePacket packet = {};
            const size_t packetSize = buildPacket(sequenceToSend, packet);
            if (packetSize == 0) {
                break;
            }
            const size_t written = Serial.write(
                reinterpret_cast<const uint8_t*>(&packet),
                packetSize
            );
            if (written != packetSize) {
                break;
            }
            sequenceToSend = packet.header.startSequence + packet.header.sampleCount;
        }
        delay(1);
    }
}

void assignWirelessNames() {
    const uint64_t chipId = ESP.getEfuseMac();
    snprintf(
        accessPointSsid,
        sizeof(accessPointSsid),
        "ThrustStand-%06llX",
        static_cast<unsigned long long>(chipId & 0xFFFFFFULL)
    );
    snprintf(
        bluetoothName,
        sizeof(bluetoothName),
        "ThrustStand-%06llX",
        static_cast<unsigned long long>(chipId & 0xFFFFFFULL)
    );
}

bool startBluetooth() {
    if (!SerialBT.begin(bluetoothName)) {
        Serial.println("ERROR: Bluetooth did not start; USB capture remains available.");
        return false;
    }
    SerialBT.setPin(CaptureConfig::BLUETOOTH_PIN);
    Serial.printf("Bluetooth: %s (PIN %s)\n", bluetoothName, CaptureConfig::BLUETOOTH_PIN);
    return true;
}

void startAccessPoint() {
    WiFi.mode(WIFI_AP);
    WiFi.setSleep(false);
    const bool accessPointStarted =
        WiFi.softAP(accessPointSsid, CaptureConfig::AP_PASSWORD, 1, false, 1);
    if (!accessPointStarted) {
        Serial.println("ERROR: Wi-Fi access point did not start; USB capture remains available.");
        return;
    }
    sampleServer.begin();
    sampleServer.setNoDelay(true);

    Serial.printf("Wi-Fi AP: %s\n", accessPointSsid);
    Serial.printf("Wi-Fi address: %s:%u\n", WiFi.softAPIP().toString().c_str(), CaptureConfig::WIFI_PORT);
}

void setup() {
    Serial.setTxBufferSize(2048);
    Serial.begin(CaptureConfig::SERIAL_BAUD);
    delay(500);

    pinMode(Pins::CS, OUTPUT);
    pinMode(Pins::DRDY, INPUT);
    digitalWrite(Pins::CS, HIGH);

    SPI.begin(Pins::SCLK, Pins::MISO, Pins::MOSI, Pins::CS);
    sendCommand(Ads1220Command::RESET);
    delay(10);
    writeRegisters();
    delay(10);

    uint8_t registers[4] = {};
    readRegisters(registers);
    Serial.printf(
        "ADS1220 registers: %02X %02X %02X %02X\n",
        registers[0],
        registers[1],
        registers[2],
        registers[3]
    );

    if (
        registers[0] != 0x3E ||
        registers[1] != Ads1220Config::DATA_RATE_REGISTER ||
        registers[2] != 0x40 ||
        registers[3] != 0x00
    ) {
        Serial.println("WARNING: ADS1220 configuration readback does not match.");
    }

    bootId = esp_random();
    assignWirelessNames();
    if (CaptureConfig::WIRELESS_MODE == CaptureConfig::WirelessMode::BLUETOOTH) {
        if (startBluetooth()) {
            const BaseType_t bluetoothTaskCreated =
                xTaskCreatePinnedToCore(bluetoothTask, "sample-bluetooth", 4096, nullptr, 1, nullptr, 0);
            if (bluetoothTaskCreated != pdPASS) {
                Serial.println("ERROR: Bluetooth capture task did not start; USB capture remains available.");
            }
        }
    } else {
        startAccessPoint();
        const BaseType_t networkTaskCreated =
            xTaskCreatePinnedToCore(networkTask, "sample-network", 4096, nullptr, 1, nullptr, 0);
        if (networkTaskCreated != pdPASS) {
            Serial.println("ERROR: Wi-Fi capture task did not start; USB capture remains available.");
        }
    }

    Serial.printf("Free heap after radio startup: %u bytes\n", ESP.getFreeHeap());

    const BaseType_t serialTaskCreated =
        xTaskCreatePinnedToCore(serialTask, "sample-usb", 4096, nullptr, 1, nullptr, 0);
    if (serialTaskCreated != pdPASS) {
        Serial.println("ERROR: USB capture task did not start.");
    }

    sendCommand(Ads1220Command::START);
    delay(20);
    Serial.printf("Capture ready: %u SPS, binary protocol v%u\n", Ads1220Config::NOMINAL_RATE_HZ, Protocol::VERSION);
}

void loop() {
    int32_t raw = 0;
    uint64_t readyAtUs = 0;

    if (!readRawConversion(raw, readyAtUs)) {
        Serial.println("ERROR: DRDY timeout.");
        delay(100);
        return;
    }

    const uint32_t sequence = nextSequence++;
    const CapturedSample sample = { static_cast<uint32_t>(readyAtUs), raw };
    storeSample(sample, sequence);
}
