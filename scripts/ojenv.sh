# Source as user jarvis: isolated environment for the OpenJarvis test install
export HOME=/opt/oj/home
export OPENJARVIS_HOME=/opt/oj/home/.openjarvis
export PATH=/opt/oj/home/.cargo/bin:/opt/oj/bin:/opt/oj/venv/bin:/usr/local/bin:/usr/bin:/bin
export RUSTUP_HOME=/opt/oj/home/.rustup CARGO_HOME=/opt/oj/home/.cargo
export UV_CACHE_DIR=/opt/oj/home/.cache/uv
export SSL_CERT_FILE=/opt/oj/ca-bundle.crt REQUESTS_CA_BUNDLE=/opt/oj/ca-bundle.crt CURL_CA_BUNDLE=/opt/oj/ca-bundle.crt CARGO_HTTP_CAINFO=/opt/oj/ca-bundle.crt
export HF_HOME=/opt/oj/home/.cache/huggingface
export OLLAMA_MODELS=/opt/oj/home/.ollama/models OLLAMA_HOST=127.0.0.1:11434
export DO_NOT_TRACK=1
export HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1
