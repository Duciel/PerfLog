# PerfLog

Performance diagnostics addon for World of Warcraft 1.12 (vanilla / Turtle WoW).

PerfLog records FPS, frame times, Lua memory, garbage collection, latency and the CPU / memory cost of every addon and frame handler into a log file. Afterwards, you open the log in an offline viewer (`Viewer/PerfLogViewer.html`) that points out the hitches and the addons behind them.

## Installation

1. Download this repository (Code → Download ZIP).
2. Extract it into `Interface\AddOns\` and **rename the folder to `!!PerfLog`**. The name must match the `.toc` file, and the `!!` prefix makes it load first so it can measure the other addons.
3. Install nampower if you don't have it, so the log is written to `CustomData\` continuously. Without it, the log goes to SavedVariables.

## Usage

See [README.txt](README.txt) for commands (`/perflog`), what is measured, and how to read the logs with the viewer.
