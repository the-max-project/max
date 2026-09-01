# MAX: AI Agent for Seniors with Dementia

## Purpose

The MAX project is designed to provide a voice-based AI agent specifically tailored for seniors with dementia.
This agent aims to maximize their quality of life by encouraging and supporting interactions with family and friends,
and helping to make technology more accessible.

The project is designed to be run on local HW and configured/managed by a trusted family member or caregiver.
A key goal is to allow the family member to spend more time visiting as family and less time with day-to-day navigation.

## Key Features

Max:

* has personalized knowledge of family and friends to help the senior stay connected
* has knowledge of the daily itinerary and upcoming appointments
* can both answer questions and prompt the senior with reminders or suggestions throughout the day
* can take notes and reminders from the senior and incorporate them into the daily itinerary
* can manage a smart TV and help play media from a curated playlist

For the primary caregiver (typically a family member) Max:

* can be configured with appropriate guidelines and reminders for the senior
* can send daily summaries of the senior's activities to the caregiver
* can take feedback to improve the agent's interactions with the senior

# Technical Overview: Multi-Service AI Application Stack

This project provides a robust, containerized environment for running a suite of AI services. It uses Docker Compose to
orchestrate a Speech-to-Text (STT) application, a LangChain agent service (`max`), an Ollama Large Language Model (LLM)
service, and an NGINX reverse proxy.

The architecture is designed for both development and production, with GPU acceleration support for high-performance
inference.

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Configuration](#configuration)
- [Running the Application](#Running-the-Application)
  - [Development](#development-mode)
  - [Production](#production-mode)
- [NVIDA GPU Support](#NVIDA-GPU-Support)

---

## Architecture

The Max Project is composed of the following services:

**1. Proxy & Web Server Service**

* **Summary:**
  Acts as the single entry point for all incoming traffic, handling SSL termination and routing requests to the appropriate backend services.
  Provides the user interface by serving a static single-page application that acts as the client for the real-time transcription service.
* **Tech Stack:** NGINX, Python, FastAPI, and Uvicorn.

**2. STT (Speech-to-Text) Service**

* **Summary:** The core engine that performs real-time audio transcription over a WebSocket connection.
* **Tech Stack:** Python, FastAPI, Uvicorn, `faster-whisper`, and NumPy. It is configured to leverage NVIDIA GPU acceleration but can fall back to CPU.

**3. Assistant Service**

* **Summary:** The core "brain" or AI agent responsible for handling complex queries, executing reasoning loops, calling tools (like Gmail and Neo4j), and acting as the main backend logic.
* **Tech Stack:** Python, FastAPI, Uvicorn, LangChain, LangGraph, Pydantic, Neo4j Python driver, and Google Auth/API Clients.

**4. TTS (Text-to-Speech) Service**

* **Summary:** Synthesizes the LLM's text responses back into audio.
* **Tech Stack:** Containerized service exposing an endpoint and configured with specific voice models (e.g., `en_US-lessac-medium`).

**5. Ollama Service**

* **Summary:** Provides the core Large Language Model (LLM) capabilities that are utilized by the Assistant service.
* **Tech Stack:**
  * Ubuntu/WSL: Ollama engine with NVIDIA GPU acceleration, hosting models such as `llama3.1:8b-instruct-q4_K_M`.
  * macOS: Ollama installed as local application

**6. Neo4j Database Service**

* **Summary:** A graph database responsible for persisting user profiles, family trees, schedules, and application relationships.
* **Tech Stack:** Neo4j graph database with the APOC plugin and Cypher query language.

**7. Proxy Service**

* **Summary:** Acts as the single entry point for all incoming traffic, handling SSL termination and routing requests to the appropriate backend services.
* **Tech Stack:** NGINX. The frontend assets are built using Node.js and Vite.

**7. Roku TV Service (Under Development)**

* **Summary:** Provides a wrapper to ROKU ECP to allow agent control of tv streaming content from multiple providers.
* **Tech Stack:** Python, FastAPI

**9. Logging Services (Optional)**

* **Summary:** Provides centralized log aggregation and dashboard visualization for the application suite.
* **Tech Stack:** Grafana and Loki (using the Loki Docker driver).

Docker named volumes (`model_cache`, `ollama_models`) are used to persist AI models and cache, preventing re-downloads
on container restarts.

## Prerequisites

This project requires Linux or WSL2 environment, and has been tested on Ubuntu 22.04 and 24.04.
Support for macOS is in progress.
The web application can be run in any browser with connectivity to the host machine, ans has been tested with
chrome on Windows and safari on an iPhone.

Before you begin, ensure you have the following installed:

* **Docker Engine**: [Installation Guide](https://docs.docker.com/engine/install/)
* **Docker Compose**: [Installation Guide](https://docs.docker.com/compose/install/)
* **Docker Plugin**: `docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions`
* **GPU Support**: either ...
  * **NVIDIA Container Toolkit**: Required for GPU support. [Installation Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
  * **macOS**: Metal / MPS included by default with macOS
* **Ollama**: for macOS, Ollama must be installed as a local application, rather than a docker container.
* **make**: A build automation tool, typically pre-installed on Linux and macOS.

## Setup

1. **Clone the Repository**:
   Max is super-repo with multiple sub-repos for the services to enable flexible future development and testing.

   ```bash
   git clone --recurse-submodules https://github.com/rbegg/max.git
   ```

   If you already cloned the repo, without the `--recurse-submodules` flag, then:

   ```bash
   cd max
   git submodule update --init --recursive
   ```
2. **Configure Environment**:

   The project uses `.env` files for configuration. Start by copying the template file for both development and
   to test the production environment. <mark> Live production should never use a file but use ENV Variables managedin the host system</mark>

   ```bash
   cp .env.template .env
   cp .env.template .env.dev
   ```

   Next, review the variables in `.env` and `.env.dev` and customize them as needed (e.g., ports, model configurations).
3. **Run the Setup Script**:

   This script creates the necessary external Docker volumes (`model_cache` and `ollama_models`) for persisting model
   data and the shared ai-network.

   ```bash
   bash scripts/setup.sh <server-name>
   ```
4. **Run the proxy setup script**:

   This script will generate SLL Certificates for development and test usage, execute from the `max/proxy/` directory.The server-name (hostname of the server running max) must be passed as a parameter or be defined as an
   environment variable `SERVER_NAME`.

   ```bash
   cd proxy
   sudo bash scripts/setup.sh <server-name>
   cd ..
   ```
5. **Run the max-assistant setup script**:

   This script will load the sample data from max/services/max-assistant/csv_data
   and authenticate the gmail client.
   The scripts are dependent on ``env.local`` located in the max-assistant directory.

   > **TODO**: cleanup use of .env files.
   >

   To run the script:

   ```bash
   cd services/max-assistant
   bash scripts/setup.sh
   cd ..
   ```

## Configuration

This project uses a `Makefile` to simplify common commands for development and to test the production environments.
The docker commands in the makefile will use the .env file for production and .env.dev for development.

### SSL

**TODO** update to inline comments in .env.template

For production, you **must** update the server name in your `.env` file:

1. Open the `.env` file.
2. Change the `PROD_SERVER_NAME` variable to your actual domain:
   ```env
   PROD_SERVER_NAME=your-actual-domain.com
   ```
3. Ensure your SSL certificates are correctly mounted in `docker-compose.prod.yaml`.

### GPU vs. CPU

By default, a system with nvida CUDA support is assumed.

To switch the `stt` service to run on CPU:

1. Open the `.env` file.
2. Change the following variables:
   ```env
   STT_DEVICE=cpu
   STT_COMPUTE_TYPE=int8
   ```
3. In `docker-compose.yaml`, comment out the `deploy` section under the `stt` service to disable the GPU reservation.

**TODO** and instructions for switching OLLAMA to CPU MODE

## Running the Application

### Optional Logging Services

If the env variable LOG is set, Grafana and Loki will be started to provide logging services.

```bash
    export LOG=1
```

### Development Mode

To start all services in development mode with hot-reloading enabled for the custom services:

```bash
make dev
```

If any dependencies change (any changes outside a services /src tree):

```bash
make dev-build
```

- The NGINX proxy service will be avail from your browser via  http  `http://localhost:8080` and https
  `https://localhost:8443` if the default ports are not in use.  Browsers will only allow microphone access over
  http to localhost.  When using a hostname, you must use https.

To stop and remove the development containers:

```bash
make dev-down
```

### Production Mode

To build and run the services in detached production like mode:

```bash
make prod
```

If any dependencies change (any changes outside a services /src tree):

```bash
make prod-build
```

- The NGINX proxy will redirect HTTP (port 80) to HTTPS (port 443).
- Either localhost or the configured domain name can be used to access the web interface.
- Ensure you have configured your DNS and SSL certificates correctly in `docker-compose.prod.yaml` and
  `./proxy/nginx/prod.conf.template`.

To stop and remove the production containers:

```bash
make prod-down
```

To bring the services down and clear the build caches:

```bash
make clean
```

### Client (Browser) access

Once the application is running, you can access the web interface at either the server-name or localhost and port you
configured.

For example if PROXY_HTTPS_PORT=9443:

```
https://127.0.0.1:9443
```

## NVIDA GPU Support

In a WSL Docker environment running the `nvidia/cuda:12.3.2-cudnn9-devel-ubuntu22.04` image, the GPU driver utilized is
the one installed on your **Windows host operating system**. You do not need to install any NVIDIA drivers within the
Docker container itself.

Here's a breakdown of how it works:

* **Windows NVIDIA Driver is Key**: The primary GPU driver is the standard NVIDIA driver you install on your Windows
  machine. This driver includes support for WSL 2, allowing it to communicate with the Linux kernel running in the WSL
  environment.
* **WSL 2 GPU Passthrough**: Windows Subsystem for Linux 2 (WSL 2) has a feature called GPU paravirtualization. This
  allows the Linux distributions running in WSL 2 to access the host machine's GPU. The Windows driver essentially
  exposes the GPU to the WSL 2 virtual machine.
* **NVIDIA Container Toolkit**: When you run a Docker container with GPU support (using the `--gpus all` flag), the
  NVIDIA Container Toolkit is responsible for mounting the necessary user-mode driver libraries and device files from
  the WSL 2 environment into your container. This allows the CUDA applications inside the container to communicate with
  the GPU.

Therefore, the architecture looks like this:

**Docker Container (e.g., `nvidia/cuda`) -> WSL 2 Environment -> Windows Host OS with NVIDIA Driver -> Physical GPU**

This setup offers a streamlined experience as you only need to manage one set of GPU drivers on your Windows host. The
`nvidia/cuda` container comes pre-packaged with the necessary CUDA Toolkit and cuDNN libraries, but it relies on the
host's driver for the low-level interaction with the GPU hardware.

---

## Verifying GPU Access

You can verify that your Docker container is correctly accessing the GPU by running the `nvidia-smi` command inside the
container:

```bash
docker run --gpus all nvidia/cuda:12.3.2-cudnn9-devel-ubuntu22.04 nvidia-smi
```

master-project/
├── .git/                      <-- The master Git repository
├── .gitmodules                <-- (If using submodules) File defining the sub-repos
│
├── services/                  <-- Directory containing your applications
│ ├── stt-app/               <-- Your current STT project lives here (as a sub-project)
│ │ ├── src/
│ │ ├── Dockerfile
│ │ └── ...
│ │
│ └── langchain-app/         <-- The new LangChain project (as another sub-project)
│ ├── src/
│ ├── Dockerfile
│ └── requirements.txt
│
├── proxy/                     <-- The reverse proxy configuration
│ ├── nginx/
│ │ ├── prod.conf
│ │ └── dev.conf
│ └── certs/
│ ├── cert.pem
│ └── key.pem
│
├── docker-compose.yaml        <-- The MASTER compose file that defines ALL services
├── docker-compose.dev.yaml    <-- Overrides for development
├── docker-compose.prod.yaml   <-- Overrides for production
└── Makefile                   <-- A master Makefile to control the whole system

```
```
