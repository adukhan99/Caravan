# Caravan Project Architecture

This document provides a high-level overview of the Caravan project structure and how the different components interact to create an agentic loop.

```mermaid
flowchart TB
    %% Nodes
    Entry["bin/main.ml<br/>(CLI Entry)"]
    
    subgraph UI_Layer ["UX & Interaction"]
        UI["lib/ui.ml<br/>(Formatting & Input)"]
    end

    subgraph Orchestrator ["The Brain (lib/)"]
        Agent["agent.ml<br/>(Agentic Loop)"]
        Session["session.ml<br/>(History)"]
        Memory["memory.ml<br/>(Context)"]
        Parser["parser.ml<br/>(Output Logic)"]
    end

    subgraph DSL_Layer ["DSL & Templates"]
        Chain["chain.ml<br/>(Composable Pipelines)"]
        Template["template.ml<br/>(Prompt Templates)"]
    end

    subgraph Interface ["Pluggable Backends"]
        direction LR
        Providers["<b>Providers</b><br/>(lib/providers/)<br/>OpenAI, Ollama, Llama.cpp"]
        Tools["<b>Tools</b><br/>(lib/tools/)<br/>FS, Shell, Web, Search"]
    end

    subgraph Settings ["Configuration"]
        TOML["~/.caravan/config.toml"]
        Config["lib/config.ml"]
    end

    %% Connections
    Entry --> UI
    UI <==> Agent
    
    Agent <--> Session
    Session --- Memory
    
    Agent ==> Providers
    Providers ==> Agent
    
    Agent --> Parser
    Parser --> Tools
    Tools ==> Agent

    Chain -.-> Agent
    Template -.-> Chain

    TOML -.-> Config
    Config -.-> Agent

    %% Styling
    classDef primary fill:#e1effe,stroke:#0969da,stroke-width:2px,color:#24292f;
    classDef secondary fill:#f3e8ff,stroke:#8250df,stroke-width:1px,color:#24292f;
    classDef interface fill:#daebd1,stroke:#1a7f37,stroke-width:1px,color:#24292f;
    classDef dsl fill:#fff8c5,stroke:#bf8700,stroke-width:1px,color:#24292f;
    
    class Agent primary;
    class Session,Memory,Parser secondary;
    class Providers,Tools interface;
    class Chain,Template dsl;
```

## Key Components

- **Agentic Loop**: The core recursive engine that manages turns between the user, the LLM, and tool execution.
- **Providers**: Standardized interface for different LLM backends.
- **Tools**: Atomic capabilities that the agent can "call" to interact with the real world (filesystem, network, etc.).
  - **delegate**: a new tool that spawns a local subagent to run an isolated task. Usage: `delegate { "subagent": "<name>", "task": "<description>" }`. Configurable via the `spinner` settings for progress verbs.
- **Session/Memory**: Maintains the state and context of the conversation. Decoupled using OCaml 5 first-class modules (`Memory.packed_memory`) to support pluggable backends such as `Buffer` (local sliding-window buffer), `Redis_store` (externalized inter-agent/multi-process shared context), and `Hierarchical` (automatic LLM-powered context compression to prevent context blow-up).
- **Parser**: Responsible for extracting structured tool calls from raw LLM text responses.
