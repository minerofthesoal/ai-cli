# GitHub Release Creation Script
# Run with: powershell -ExecutionPolicy Bypass -File create-release.ps1

$owner = "minerofthesoal"
$repo = "ai-cli"
$tag = "v2.4.0.0.1"
$releaseName = "Release v2.4.0.0.1"
$body = @"
## AI CLI v2.4.0.0.1

### Changes
- Added AUR (Arch User Repository) package support
- Package includes PKGBUILD and .SRCINFO for Arch Linux installation

### Installation

#### Arch Linux (AUR)
``````bash
git clone https://aur.archlinux.org/ai-cli.git
cd ai-cli
makepkg -si
``````

#### Universal Installation
``````bash
chmod +x main-v2.4
sudo cp main-v2.4 /usr/local/bin/ai
``````

### Usage
``````bash
ai install-deps           # auto-detects CUDA 6.1+
ai recommended            # see all curated models
ai ask "Hello!"
ai -gui                   # launch TUI
``````

For more information, visit the [GitHub repository](https://github.com/minerofthesoal/ai-cli)
"@

# Try to get GitHub token from environment or ask user
$token = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN')

if (-not $token) {
    Write-Host "GitHub token not found in environment."
    Write-Host "Please provide your GitHub Personal Access Token:"
    Write-Host "(Generate one at: https://github.com/settings/tokens)"
    $token = Read-Host -AsSecureString
    $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($token))
}

# Create the request
$headers = @{
    "Authorization" = "token $token"
    "Accept" = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$body = $body | ConvertTo-Json

$url = "https://api.github.com/repos/$owner/$repo/releases"

$payload = @{
    tag_name = $tag
    name = $releaseName
    body = $body
    draft = $false
    prerelease = $false
} | ConvertTo-Json

Write-Host "Creating release $tag..."
Write-Host "URL: $url"

try {
    $response = Invoke-WebRequest -Uri $url -Method POST -Headers $headers -Body $payload -ContentType "application/json"
    Write-Host "Release created successfully!"
    Write-Host "Response: $($response.Content)"
} catch {
    Write-Host "Error creating release:"
    Write-Host $_.Exception.Message
    if ($_.ErrorDetails) {
        Write-Host $_.ErrorDetails.Message
    }
}
