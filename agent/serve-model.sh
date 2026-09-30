#!/usr/bin/env bash
# Serve Nemotron 3.5 Lightning for the booth agent.
#
# Three traps, each of which cost a restart cycle:
#  1. A user systemd unit `vllm-server.service` owns port 8000 and recreates a
#     Qwen container whenever it is removed -- `docker rm -f` loses that race
#     every time. Stop the UNIT, not just the container.
#  2. vllm/vllm-openai's ENTRYPOINT is ["vllm","serve"], so the docker command
#     must be ONLY the model id plus flags. Passing "vllm serve <model>" gives
#     "unrecognized arguments: serve ..."; passing "serve <model>" gives
#     "unrecognized arguments: <model>".
#  3. Verify /v1/models reports the id you asked for. A container that is "Up"
#     can still be Restarting in a crash loop, and the old model keeps serving.
set -x
systemctl --user stop vllm-server.service 2>/dev/null
systemctl --user disable vllm-server.service 2>/dev/null
docker rm -f vllm-server e2-llm 2>/dev/null
sleep 5
ss -tln | grep ':8000' || echo "port 8000 free"

docker run -d --name e2-llm --gpus all --ipc=host --restart unless-stopped \
  -p 0.0.0.0:8000:8000 \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  vllm/vllm-openai:latest \
  nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 \
  --host 0.0.0.0 --port 8000 \
  --max-model-len 32768 --gpu-memory-utilization 0.80 \
  --reasoning-parser nemotron_v3 \
  --enable-auto-tool-choice --tool-call-parser qwen3_xml
sleep 10
docker ps --format '{{.Names}} {{.Status}}' | grep e2-llm
docker network connect openshell-docker e2-llm 2>/dev/null
docker inspect e2-llm -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}'
