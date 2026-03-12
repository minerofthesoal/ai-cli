# ai-cli — Package Distribution Setup

## Overview

Three GitHub Actions workflows build and publish ai-cli automatically
when you push a tag like `v2.8.5.5`.

```
git tag v2.8.5.5
git push origin v2.8.5.5
```

This triggers:
  1. `.deb` build → uploaded to GitHub Releases
  2. AUR package → pushed to aur.archlinux.org
  3. Pacstall package → PR opened to pacstall-programs

---

## Required GitHub Secrets

Go to: **Settings → Secrets and variables → Actions → New repository secret**

### 1. AUR_SSH_KEY (for Arch Linux AUR)

Generate a dedicated SSH key for AUR:

```bash
# On your local machine:
ssh-keygen -t ed25519 -C "ai-cli AUR bot" -f ~/.ssh/aur_bot_key -N ""

# Copy the PUBLIC key to AUR:
cat ~/.ssh/aur_bot_key.pub
# → paste at https://aur.archlinux.org/account/ → Edit Profile → SSH Public Key

# Add the PRIVATE key as a GitHub secret:
cat ~/.ssh/aur_bot_key
# → copy entire contents → GitHub Secrets → Name: AUR_SSH_KEY
```

Then register your package on AUR:
```bash
# Clone the (initially empty) AUR repo for your package:
ssh aur@aur.archlinux.org info ai-cli   # check if it exists

# If it doesn't exist yet, create it by pushing:
git clone ssh://aur@aur.archlinux.org/ai-cli.git
cd ai-cli
cp /path/to/PKGBUILD .
cp /path/to/.SRCINFO .    # generate with: makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "init: ai-cli"
git push
```

### 2. PAC_GITHUB_TOKEN (for Pacstall PR)

Create a fine-grained Personal Access Token:
1. Go to GitHub → Settings → Developer settings → Personal access tokens → Fine-grained
2. Resource owner: **your account**
3. Repository access: **Only select repositories** → your fork of `pacstall/pacstall-programs`
4. Permissions:
   - Contents: **Read and Write**
   - Pull requests: **Read and Write**
5. Copy the token → GitHub Secrets → Name: `PAC_GITHUB_TOKEN`

> Without this secret the Pacstall workflow still runs — it just generates
> the `.pacscript` as an artifact instead of auto-submitting the PR.

---

## Manual Steps (one-time)

### Submit to AUR manually (first time)

If the AUR package doesn't exist yet, you need to create it once manually
from an Arch Linux machine (or use a Docker container):

```bash
# Option A: native Arch
docker run --rm -it archlinux:latest bash
pacman -Syu --noconfirm base-devel git
useradd -m builder && su builder
git clone https://aur.archlinux.org/ai-cli.git   # will be empty first time
cd ai-cli
# paste your PKGBUILD and .SRCINFO
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "init: ai-cli v2.8.5.5"
git push
```

### Submit to Pacstall manually

```bash
# Fork pacstall-programs on GitHub, then:
git clone https://github.com/YOUR_FORK/pacstall-programs.git
cd pacstall-programs
git remote add upstream https://github.com/pacstall/pacstall-programs.git
git fetch upstream master
git checkout -b ai-cli-v2.8.5.5 upstream/master
mkdir -p packages/ai-cli
cp /path/to/ai-cli.pacscript packages/ai-cli/
git add packages/ai-cli/ai-cli.pacscript
git commit -m "feat(ai-cli): add v2.8.5.5"
git push origin ai-cli-v2.8.5.5

# Then open a PR at:
# https://github.com/pacstall/pacstall-programs/compare
```

---

## Workflow Files

| File | Purpose |
|------|---------|
| `.github/workflows/build-deb.yml`      | Build `.deb`, create GitHub Release |
| `.github/workflows/publish-aur.yml`    | Generate PKGBUILD, push to AUR |
| `.github/workflows/publish-pacstall.yml` | Generate `.pacscript`, open Pacstall PR |
| `.github/workflows/release.yml`        | Master workflow — runs all three |
| `PKGBUILD`                             | AUR build script (keep in repo) |
| `ai-cli.pacscript`                     | Pacstall package script (keep in repo) |

---

## Release Checklist

```bash
# 1. Update version in main.sh
sed -i 's/^VERSION=.*/VERSION="2.8.5.6"/' main.sh

# 2. Commit
git add main.sh
git commit -m "release: v2.8.5.6"

# 3. Tag — this triggers all workflows
git tag v2.8.5.6
git push origin main --tags

# 4. Watch the Actions tab for progress
# 5. Check GitHub Releases for the .deb
# 6. Verify AUR: https://aur.archlinux.org/packages/ai-cli
# 7. Approve/merge the Pacstall PR
```

---

## User Install Commands (after publishing)

```bash
# Debian / Ubuntu / Mint / Pop!_OS
wget https://github.com/minerofthesoal/ai-cli/releases/latest/download/ai-cli_all.deb
sudo dpkg -i ai-cli_all.deb
sudo apt-get install -f

# Arch Linux (AUR)
yay -S ai-cli        # yay
paru -S ai-cli       # paru
pamac install ai-cli # Manjaro

# Pacstall (Ubuntu-based)
pacstall -I ai-cli

# Direct (any distro)
curl -sL https://raw.githubusercontent.com/minerofthesoal/ai-cli/main/main.sh \
  | sudo tee /usr/local/bin/ai > /dev/null
sudo chmod +x /usr/local/bin/ai
```
