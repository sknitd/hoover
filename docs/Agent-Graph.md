# Hoover implementation graph

```mermaid
graph TD
  Lead[Integration and app lifecycle] --> Core[Core: hover, filesystem, search]
  Lead --> Finder[Finder: Accessibility tracking]
  Lead --> UI[Interface: spatial tree and file HUD]
  Lead --> Metadata[Metadata: local type extractors]
  Lead --> Services[Settings and native file actions]
  Core --> Eval[Evaluation and packaging]
  Finder --> Eval
  UI --> Eval
  Metadata --> Eval
  Services --> Eval
  Eval --> Lead
  Lead --> Eval
```

Each implementation agent follows inspect → implement → self-review → test/repair → report.
The evaluation agent follows requirements → tests/build → findings → repair request → recheck.
Integration follows contract review → integrate → test → repair → evaluation → package.
The available environment supports six concurrent subagents plus the integration agent.
The requested maximum of twenty is a ceiling, not a required agent count.

No user-facing demo mode or simulated Finder session is included.
