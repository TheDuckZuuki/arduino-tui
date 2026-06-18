# Arduino TUI

> ⚠️ **AI-Generated Project**
>
> This project was created **entirely with AI assistance**. The source code, features, implementation details, and documentation were generated and refined using AI tools. While functional and tested, there may still be bugs, inefficiencies, or edge cases that require human review.

A terminal user interface (TUI) for **arduino-cli**, built with Bash and `dialog`.

Arduino TUI provides a simple menu-driven interface for managing Arduino projects without memorizing command-line arguments. It wraps `arduino-cli` functionality in an easy-to-use text interface for compiling, uploading, board management, and library management.

## Features

- 📁 Select Arduino sketches by path
- 🔍 Search and select boards using FQBN autocomplete
- 🔌 Auto-detect connected boards and serial ports
- ⚡ Compile sketches
- 🚀 Upload sketches
- 🔄 Compile and upload in a single action
- 📚 Library Manager
- 🛠 Board Manager
- 💾 Persistent configuration storage
- 📝 Stores selected board information directly in sketch files
- 📜 Live compile and upload logs

## Requirements

### Required
- Linux
- Bash 4+
- Python 3
- dialog
- arduino-cli

## Installation

### Install Arduino CLI

```bash
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh
```

### Install dialog

#### Debian / Ubuntu
```bash
sudo apt install dialog
```

#### Fedora
```bash
sudo dnf install dialog
```

#### Arch Linux
```bash
sudo pacman -S dialog
```

## How to Run

```bash
chmod +x arduino-tui.sh
./arduino-tui.sh
```

Or install system-wide:

```bash
sudo cp arduino-tui.sh /usr/local/bin/arduino-tui
chmod +x /usr/local/bin/arduino-tui
arduino-tui
```

## Disclaimer

This project is an unofficial wrapper around arduino-cli and is not affiliated with or endorsed by Arduino.
