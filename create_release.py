#!/usr/bin/env python3
"""
GitHub Release Creation Script
Usage: python3 create_release.py <github_token>
"""

import sys
import json
import urllib.request
import urllib.error

def create_release(token, owner, repo, tag, name, body):
    """Create a GitHub release using the API"""
    
    url = f"https://api.github.com/repos/{owner}/{repo}/releases"
    
    payload = {
        "tag_name": tag,
        "name": name,
        "body": body,
        "draft": False,
        "prerelease": False
    }
    
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "AI-CLI-Release"
    }
    
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, headers=headers, method='POST')
    
    try:
        with urllib.request.urlopen(req) as response:
            result = json.loads(response.read().decode('utf-8'))
            print(f"✅ Release created successfully!")
            print(f"   Name: {result.get('name')}")
            print(f"   Tag: {result.get('tag_name')}")
            print(f"   URL: {result.get('html_url')}")
            return True
    except urllib.error.HTTPError as e:
        error_data = json.loads(e.read().decode('utf-8'))
        print(f"❌ Error creating release: {error_data.get('message')}")
        if 'errors' in error_data:
            for error in error_data['errors']:
                print(f"   - {error.get('message')}")
        return False
    except Exception as e:
        print(f"❌ Unexpected error: {str(e)}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 create_release.py <github_token>")
        print("\nExample:")
        print("  python3 create_release.py ghp_xxxxxxxxxxxx")
        print("\nGenerate a token at: https://github.com/settings/tokens")
        sys.exit(1)
    
    token = sys.argv[1]
    
    release_body = """## AI CLI v2.4.0.0.1

### Changes
- ✨ Added AUR (Arch User Repository) package support
- 📦 Added PKGBUILD for Arch Linux packaging
- 📋 Added .SRCINFO metadata file
- 📖 Added comprehensive AUR setup guide

### Installation

#### Arch Linux (via AUR)
```bash
git clone https://aur.archlinux.org/ai-cli.git
cd ai-cli
makepkg -si
```

#### Universal Installation
```bash
chmod +x main-v2.4
sudo cp main-v2.4 /usr/local/bin/ai
```

### Quick Start
```bash
ai install-deps           # auto-detect and install dependencies
ai recommended            # see all curated AI models
ai ask "Hello!"          # start chatting
ai -gui                  # launch interactive TUI
ai canvas new python     # start AI-assisted coding
```

### Features
- 🤖 Multi-AI support: OpenAI, Claude, Gemini, HuggingFace, local GGUF
- 🖥️ Full platform support: Linux, macOS, Windows 10+
- ⚡ CPU-only or GPU (CUDA/ROCm) acceleration
- 🎨 Canvas mode for AI-assisted development
- 🎯 Fine-tuning with TTM/MTM/Mtm support
- 🧠 Local model support

### Documentation
- [GitHub Repository](https://github.com/minerofthesoal/ai-cli)
- [AUR Setup Guide](https://github.com/minerofthesoal/ai-cli/blob/main/AUR_SETUP_GUIDE.md)

### License
MIT License
"""
    
    print("🚀 Creating GitHub Release...")
    print("   Owner: minerofthesoal")
    print("   Repo: ai-cli")
    print("   Tag: v2.4.0.0.1")
    print("   Name: Release v2.4.0.0.1")
    print()
    
    success = create_release(
        token=token,
        owner="minerofthesoal",
        repo="ai-cli",
        tag="v2.4.0.0.1",
        name="Release v2.4.0.0.1",
        body=release_body
    )
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
