# AI CLI - AUR Package Setup Guide

## Overview
The AI CLI AUR package has been successfully created and committed to the repository. This guide explains the setup and next steps.

## What Has Been Done

✅ **Created PKGBUILD** - The Arch Linux package build recipe
✅ **Created .SRCINFO** - Package metadata for AUR
✅ **Committed to GitHub** - Both files pushed to main branch
✅ **Created Git Tag** - v2.4.0.0.1 tag created and pushed
✅ **Ready for Release** - GitHub release awaiting final creation

## Files Added

### PKGBUILD
Standard Arch Linux package build file that includes:
- Package metadata (name, version, description)
- Dependencies (bash, python>=3.10, curl, jq)
- Optional dependencies (CUDA, ROCm)
- Build and installation instructions

### .SRCINFO
AUR metadata file containing:
- Package information in simplified format
- Version and release information
- Dependency specifications

## Installation Methods

### For Arch Linux Users (via AUR)

Once submitted to AUR, users can install with:
```bash
git clone https://aur.archlinux.org/ai-cli.git
cd ai-cli
makepkg -si
```

Or using an AUR helper like yay:
```bash
yay -S ai-cli
```

### For Other Linux/macOS

```bash
chmod +x main-v2.4
sudo cp main-v2.4 /usr/local/bin/ai
```

## GitHub Release - v2.4.0.0.1

### Status
- ✅ Tag created locally: `v2.4.0.0.1`
- ✅ Tag pushed to GitHub
- ⏳ Release creation requires authentication

### To Create the Release

Visit: https://github.com/minerofthesoal/ai-cli/releases

1. Click "Draft a new release"
2. Select tag `v2.4.0.0.1`
3. Use this title: "Release v2.4.0.0.1"
4. Use this description:

```
## AI CLI v2.4.0.0.1

### Changes
- Added AUR (Arch User Repository) package support
- Package includes PKGBUILD and .SRCINFO for Arch Linux installation

### Installation

#### Arch Linux (AUR)
git clone https://aur.archlinux.org/ai-cli.git
cd ai-cli
makepkg -si

#### Universal Installation
chmod +x main-v2.4
sudo cp main-v2.4 /usr/local/bin/ai

### Features
- Universal AI CLI with support for multiple AI providers
- TUI (Terminal User Interface)
- Fine-tuning capabilities
- Canvas mode for AI-assisted coding
- Support for GGUF, PyTorch, Diffusers, OpenAI, Claude, Gemini
- Cross-platform: Windows 10, Linux, macOS
```

5. Click "Publish release"

## Next Steps for AUR Submission

1. Create an AUR account at https://aur.archlinux.org
2. The AUR maintainer should:
   - Clone the package from GitHub  
   - Push to `ssh+git://aur@aur.archlinux.org/ai-cli.git`
   - Users can then install via AUR

## Package Information

**Name:** ai-cli
**Version:** 2.4.0
**Release:** 1
**Architectures:** x86_64, aarch64
**License:** MIT
**Homepage:** https://github.com/minerofthesoal/ai-cli

## Command Reference

After installation, use `ai` command:

```bash
ai install-deps           # auto-detect and install deps
ai recommended            # see curated models
ai ask "Your question"    # chat mode
ai -gui                   # launch TUI
ai canvas new python      # start Canvas mode
```

## Repository Status

- Repository: https://github.com/minerofthesoal/ai-cli
- Latest tag: v2.4.0.0.1
- Main files: main-v2.3.5, main-v2.4
- License: MIT
