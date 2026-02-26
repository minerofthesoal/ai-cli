# ai-cli

chmod +x ai.sh && sudo cp ai.sh /usr/local/bin/ai
ai install-deps           # auto-detects CUDA 6.1+
ai recommended            # see all curated models
ai recommended download 1 # get supertiny-llama3 0.25B (any CPU!)
ai recommended use 1
ai ask "Hello!"
ai -gui                   # launch TUI
ai canvas new bot python  # start coding with AI
ai canvas ask "Make a CLI chatbot"
ai canvas run
