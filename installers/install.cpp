/*
 * AI CLI — C++ Installer
 * Cross-platform installer for ai-cli
 * Compile: g++ -std=c++17 -o install install.cpp -lcurl
 * Usage:   ./install [--prefix /usr/local] [--branch main] [--force] [--uninstall]
 */

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <filesystem>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

// ── Constants ────────────────────────────────────────────────────────────────
const std::string REPO_OWNER = "minerofthesoal";
const std::string REPO_NAME  = "ai-cli";
const std::string BINARY     = "ai";

// ── Colors ───────────────────────────────────────────────────────────────────
const char* GRN = "\033[92m";
const char* YLW = "\033[93m";
const char* RED = "\033[91m";
const char* CYN = "\033[96m";
const char* BLD = "\033[1m";
const char* RST = "\033[0m";

void ok(const std::string& m)   { std::cout << GRN << "[OK]"  << RST << "  " << m << "\n"; }
void info(const std::string& m) { std::cout << CYN << "[..]"  << RST << "  " << m << "\n"; }
void warn(const std::string& m) { std::cout << YLW << "[!!]"  << RST << "  " << m << "\n"; }
void err(const std::string& m)  { std::cerr << RED << "[ERR]" << RST << " " << m << "\n"; }

// ── Platform Detection ──────────────────────────────────────────────────────
struct Platform {
    std::string os;      // linux, macos, windows, wsl
    std::string arch;    // x86_64, arm64, armv7l
    std::string distro;  // arch, ubuntu, fedora, etc.
};

Platform detect_platform() {
    Platform p;
#ifdef __APPLE__
    p.os = "macos";
#elif defined(_WIN32)
    p.os = "windows";
#else
    p.os = "linux";
    // Check for WSL
    std::ifstream proc_ver("/proc/version");
    if (proc_ver.is_open()) {
        std::string line;
        std::getline(proc_ver, line);
        for (auto& c : line) c = tolower(c);
        if (line.find("microsoft") != std::string::npos)
            p.os = "wsl";
    }
#endif

#if defined(__x86_64__) || defined(_M_X64)
    p.arch = "x86_64";
#elif defined(__aarch64__) || defined(_M_ARM64)
    p.arch = "arm64";
#elif defined(__arm__)
    p.arch = "armv7l";
#else
    p.arch = "unknown";
#endif

    // Detect Linux distro
    std::ifstream os_release("/etc/os-release");
    if (os_release.is_open()) {
        std::string line;
        while (std::getline(os_release, line)) {
            if (line.rfind("ID=", 0) == 0) {
                p.distro = line.substr(3);
                // Remove quotes
                p.distro.erase(
                    std::remove(p.distro.begin(), p.distro.end(), '"'),
                    p.distro.end());
                break;
            }
        }
    }
    return p;
}

bool needs_sudo() {
#ifdef _WIN32
    return false;
#else
    return geteuid() != 0;
#endif
}

// ── Shell command execution ─────────────────────────────────────────────────
int exec(const std::string& cmd) {
    return system(cmd.c_str());
}

std::string exec_capture(const std::string& cmd) {
    std::string result;
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return result;
    char buf[256];
    while (fgets(buf, sizeof(buf), pipe))
        result += buf;
    pclose(pipe);
    // Trim trailing newline
    while (!result.empty() && (result.back() == '\n' || result.back() == '\r'))
        result.pop_back();
    return result;
}

// ── Version helpers ─────────────────────────────────────────────────────────
std::string get_installed_version(const fs::path& prefix) {
    fs::path ai_bin = prefix / "bin" / BINARY;
    if (!fs::exists(ai_bin)) return "";
    std::ifstream f(ai_bin);
    std::string line;
    while (std::getline(f, line)) {
        if (line.rfind("VERSION=", 0) == 0) {
            auto start = line.find('"');
            auto end = line.rfind('"');
            if (start != std::string::npos && end > start)
                return line.substr(start + 1, end - start - 1);
        }
    }
    return "";
}

std::string fetch_remote_version(const std::string& branch) {
    std::string url = "https://raw.githubusercontent.com/" +
        REPO_OWNER + "/" + REPO_NAME + "/" + branch + "/main.sh";
    std::string cmd = "curl -fsSL '" + url + "' 2>/dev/null | grep '^VERSION=' | head -1 | cut -d'\"' -f2";
    return exec_capture(cmd);
}

// ── Install ─────────────────────────────────────────────────────────────────
bool do_install(const fs::path& prefix, const std::string& branch, bool dry_run) {
    std::string raw_base = "https://raw.githubusercontent.com/" +
        REPO_OWNER + "/" + REPO_NAME + "/" + branch;

    fs::path bin_dir = prefix / "bin";
    fs::path share_dir = prefix / "share" / "ai-cli";
    fs::path dest = bin_dir / BINARY;

    info("Installing ai-cli to " + dest.string() + "...");
    if (dry_run) {
        info("[dry-run] Would download and install main.sh");
        return true;
    }

    // Create directories
    std::string sudo_pfx = needs_sudo() ? "sudo " : "";
    exec(sudo_pfx + "mkdir -p " + bin_dir.string());
    exec(sudo_pfx + "mkdir -p " + share_dir.string());

    // Download main script
    std::string tmp = "/tmp/ai-cli-install-tmp.sh";
    std::string dl_cmd = "curl -fsSL '" + raw_base + "/main.sh' -o " + tmp;
    if (exec(dl_cmd) != 0) {
        err("Download failed");
        return false;
    }

    // Verify file
    if (!fs::exists(tmp) || fs::file_size(tmp) == 0) {
        err("Downloaded file is empty");
        return false;
    }

    // Install
    exec(sudo_pfx + "install -m 0755 " + tmp + " " + dest.string());
    ok("Installed " + dest.string());

    // Download support files
    for (auto& f : {"misc/requirements.txt", "misc/package.json"}) {
        std::string fname = fs::path(f).filename().string();
        std::string target = (share_dir / fname).string();
        exec("curl -fsSL '" + raw_base + "/" + f + "' -o " + target + " 2>/dev/null");
    }

    // Config directory
    std::string config_dir = std::string(getenv("HOME") ? getenv("HOME") : "~") + "/.config/ai-cli";
    exec("mkdir -p " + config_dir);

    std::string keys_path = config_dir + "/keys.env";
    if (!fs::exists(keys_path)) {
        std::ofstream keys(keys_path);
        keys << "# AI CLI API Keys\n"
             << "# ai keys set OPENAI_API_KEY sk-...\n"
             << "# ai keys set ANTHROPIC_API_KEY sk-ant-...\n";
        ok("Created " + keys_path);
    }

    // Cleanup
    fs::remove(tmp);
    return true;
}

// ── Uninstall ───────────────────────────────────────────────────────────────
void do_uninstall(const fs::path& prefix) {
    std::string sudo_pfx = needs_sudo() ? "sudo " : "";
    fs::path bin = prefix / "bin" / BINARY;
    fs::path share = prefix / "share" / "ai-cli";

    if (fs::exists(bin)) {
        exec(sudo_pfx + "rm -f " + bin.string());
        ok("Removed " + bin.string());
    }
    if (fs::exists(share)) {
        exec(sudo_pfx + "rm -rf " + share.string());
        ok("Removed " + share.string());
    }
    warn("Config at ~/.config/ai-cli/ preserved.");
}

// ── Argument Parsing ────────────────────────────────────────────────────────
struct Args {
    std::string prefix  = "/usr/local";
    std::string branch  = "main";
    bool force    = false;
    bool dry_run  = false;
    bool uninstall = false;
    bool check    = false;
    bool no_deps  = false;
    bool help     = false;
};

Args parse_args(int argc, char* argv[]) {
    Args a;
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--prefix" && i + 1 < argc)  a.prefix = argv[++i];
        else if (arg == "--branch" && i + 1 < argc) a.branch = argv[++i];
        else if (arg == "--force")     a.force = true;
        else if (arg == "--dry-run")   a.dry_run = true;
        else if (arg == "--uninstall") a.uninstall = true;
        else if (arg == "--check")     a.check = true;
        else if (arg == "--no-deps")   a.no_deps = true;
        else if (arg == "-h" || arg == "--help") a.help = true;
    }
    return a;
}

void print_usage() {
    std::cout << "AI CLI — C++ Installer\n\n"
              << "Usage: install [OPTIONS]\n\n"
              << "Options:\n"
              << "  --prefix DIR    Install prefix (default: /usr/local)\n"
              << "  --branch NAME   Git branch (default: main)\n"
              << "  --force         Force reinstall\n"
              << "  --no-deps       Skip dependency installation\n"
              << "  --dry-run       Preview actions\n"
              << "  --check         Check for updates\n"
              << "  --uninstall     Remove ai-cli\n"
              << "  -h, --help      Show this help\n\n"
              << "Compile: g++ -std=c++17 -o install install.cpp\n";
}

// ── Main ────────────────────────────────────────────────────────────────────
int main(int argc, char* argv[]) {
    Args args = parse_args(argc, argv);

    if (args.help) {
        print_usage();
        return 0;
    }

    fs::path prefix(args.prefix);
    Platform plat = detect_platform();

    std::cout << "\n" << CYN << "==================================================" << RST << "\n";
    std::cout << BLD << "  AI CLI — C++ Installer" << RST << "\n";
    std::cout << CYN << "==================================================" << RST << "\n\n";

    info("Platform: " + plat.os + " | Arch: " + plat.arch +
         " | Distro: " + plat.distro);

    if (args.uninstall) {
        do_uninstall(prefix);
        return 0;
    }

    // Version check
    std::string remote_ver = fetch_remote_version(args.branch);
    std::string installed_ver = get_installed_version(prefix);

    if (!remote_ver.empty()) info("Remote version:    v" + remote_ver);
    if (!installed_ver.empty()) info("Installed version: v" + installed_ver);

    if (args.check) {
        if (remote_ver.empty()) { err("Could not fetch remote version"); return 1; }
        if (installed_ver == remote_ver) ok("Up to date!");
        else if (!installed_ver.empty()) warn("Update available: " + installed_ver + " -> " + remote_ver);
        else info("Not installed yet");
        return 0;
    }

    if (!installed_ver.empty() && installed_ver == remote_ver && !args.force) {
        ok("Already up to date (v" + installed_ver + "). Use --force to reinstall.");
        return 0;
    }

    if (!do_install(prefix, args.branch, args.dry_run)) {
        return 1;
    }

    // Run deps
    if (!args.no_deps && !args.dry_run) {
        fs::path ai_bin = prefix / "bin" / BINARY;
        if (fs::exists(ai_bin)) {
            info("Installing dependencies...");
            exec(ai_bin.string() + " install-deps");
        }
    }

    std::cout << "\n" << GRN << "==================================================" << RST << "\n";
    std::cout << GRN << "  ai-cli v" << (remote_ver.empty() ? "latest" : remote_ver) << " installed!" << RST << "\n";
    std::cout << GRN << "==================================================" << RST << "\n\n";
    std::cout << "  ai --help          Show commands\n";
    std::cout << "  ai ask \"hello\"     Quick question\n";
    std::cout << "  ai chat            Interactive chat\n";
    std::cout << "  ai recommended     Browse 195 models\n\n";

    return 0;
}
