# Thrust Stand Studio

Thrust Stand Studio is a macOS app for viewing load-cell readings alongside video. It can save time points, fit a straight line to known weights, and export calibrated CSVs.

From the project root, run `swift run ThrustStandStudio`. The app finds the `runs/` directory automatically. Select a run in the sidebar and choose **Time points** or **Weight points**.

## Sync video and data

In **Time points**, pause the video on an event visible in both the video and trace, click the matching point on the graph, and add the time point. The app saves the offset as data time minus video time in `run.json`, writes the markers to `camera/sync.csv`, and updates `camera_time_s` in `data.csv`. It copies a selected video into the run's `camera/` folder.

The included clips for launches 1 and 2 use the same offsets as the website, adjusted for the start of each cropped data window. Launches 3 and 4 have no video. The full recordings are not included.

## Calibrate

In **Weight points**, select a steady section of the trace and enter the total weight on the load cell. Add at least two sections with different known loads, then fit the calibration. Use consistent weights, including whichever mount is on the cell. Save the workspace to keep the selected sections and fit in `.studio/run-calibration-workspace.json`.

**Export corrected CSVs** writes `data-calibrated.csv` beside each run using:

```text
force in pounds = (raw counts - zero) / counts per pound
```

The launch examples only cover the graph windows. They don't include the earlier calibration sections, so use a recording that contains known-weight sections to make a new fit. Saving time points changes the example files; make a copy of `runs/` first if you want to preserve them exactly as provided.

## Run format

Each folder under `runs/` needs a `data.csv` with `time_s` and `raw` columns. Optional `run.json` metadata sets the label and camera file. Paths in the manifest are relative to the run folder. The examples also include `calibrated_force_lb` and a copy of the website's reduced graph data; the app currently plots raw counts.
