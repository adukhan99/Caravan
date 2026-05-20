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
    classDef primary fill:#f9f,stroke:#333,stroke-width:2px;
    classDef secondary fill:#bbf,stroke:#333,stroke-width:1px;
    classDef interface fill:#dfd,stroke:#333,stroke-width:1px;
    classDef dsl fill:#ffd,stroke:#333,stroke-width:1px;
    
    class Agent primary;
    class Session,Memory,Parser secondary;
    class Providers,Tools interface;
    class Chain,Template dsl;
```

## Key Components

- **Agentic Loop**: The core recursive engine that manages turns between the user, the LLM, and tool execution.
- **Providers**: Standardized interface for different LLM backends.
- **Tools**: Atomic capabilities that the agent can "call" to interact with the real world (filesystem, network, etc.).
- **Session/Memory**: Maintains the state and context of the conversation. Decoupled using OCaml 5 first-class modules (`Memory.packed_memory`) to support pluggable backends such as `Buffer` (local sliding-window buffer), `Redis_store` (externalized inter-agent/multi-process shared context), and `Hierarchical` (automatic LLM-powered context compression to prevent context blow-up).
- **Parser**: Responsible for extracting structured tool calls from raw LLM text responses.
