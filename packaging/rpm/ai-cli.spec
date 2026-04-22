Name:           ai-cli
Version:        3.2.1
Release:        1%{?dist}
Summary:        AI CLI — local + cloud LLM terminal toolkit
License:        MIT
URL:            https://github.com/minerofthesoal/ai-cli
Source0:        %{name}-%{version}.tar.gz

Requires:       bash >= 5.0
Requires:       python3 >= 3.10
Requires:       curl
Requires:       git
Recommends:     python3-pip
Recommends:     ffmpeg
Suggests:       jq
Suggests:       nodejs

BuildArch:      noarch

%description
Unified terminal interface for local and cloud AI models.
Supports GGUF (llama.cpp), OpenAI, Claude, Gemini, Groq, Mistral APIs.
Includes model training, RLHF, Canvas v3 workspace, and 195 curated models.

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/%{name}
mkdir -p %{buildroot}/usr/share/doc/%{name}
mkdir -p %{buildroot}/usr/share/licenses/%{name}

install -m 0755 main.sh %{buildroot}/usr/bin/ai
install -m 0644 misc/requirements.txt %{buildroot}/usr/share/%{name}/ || true
install -m 0644 misc/package.json %{buildroot}/usr/share/%{name}/ || true
install -m 0644 README.md %{buildroot}/usr/share/doc/%{name}/ || true
install -m 0644 LICENSE %{buildroot}/usr/share/licenses/%{name}/ || true

%files
/usr/bin/ai
/usr/share/%{name}/
/usr/share/doc/%{name}/
/usr/share/licenses/%{name}/

%post
echo ""
echo "  ai-cli %{version} installed!"
echo "  Run: ai --help"
echo ""
