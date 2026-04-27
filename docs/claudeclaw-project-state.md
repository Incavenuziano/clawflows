# ClaudeClaw: Estado do Projeto

Use este arquivo para dar contexto a novas sessões. Resume o que foi decidido, o que existe e o que vem a seguir.

---

## O Que É ClaudeClaw

Um agente autônomo que vive no servidor do usuário, usando **Claude Max subscription** (não API paga). Não é copiloto de IDE nem chatbot. É um daemon que acorda, verifica tarefas pendentes, chama Claude se necessário, executa o resultado, aprende, volta a dormir.

**Meta:** rodar 24/7, crescer em capacidade ao longo do tempo, sem surpresas de custo.

---

## Stack Decidida

| Componente | Solução | Notas |
|-----------|---------|-------|
| **Runtime Claude** | `claude -p "..."` (Claude Code headless) | Usa Max subscription, não API key |
| **Memória** | [claude-mem](https://github.com/Incavenuziano/claude-mem) | HTTP worker :37777, SQLite FTS5 + Chroma vector DB, auto-compressão |
| **Skills/Subagents** | [awesome-claude-code-subagents](https://github.com/Incavenuziano/awesome-claude-code-subagents) | ~100 agents `.md`, droppados em `.claude/agents/` |
| **Daemon** | systemd timer a cada 5 min | `oneshot` service, não loop contínuo |
| **Tarefas** | SQLite (`tasks.db`) | Cron bash checa → só chama Claude se há task |
| **Auditoria** | SQLite (`calls.db`, `audit_log`) | Rastrear quota consumida + histórico |
| **Referência arquitetural** | [Hermes Agent (NousResearch)](https://github.com/NousResearch/hermes-agent) | Só conceitos — usa API keys, não serve como base de código |

---

## Decisões Importantes

### Por que `claude -p` e não API direta?
Claude Max subscription não expõe API keys para uso programático direto. O caminho legítimo e suportado é Claude Code em modo headless: `claude -p "prompt aqui"`. Bash/cron/SQLite chamados a qualquer frequência = custo zero; só invocações ao modelo consomem quota.

### Por que Hermes é só referência?
Hermes usa API keys do modelo (OpenAI/Anthropic API), enquanto nosso alvo é Max subscription. A arquitetura de Hermes (FTS5 + LLM summarization para memória, daemon loop, skill auto-creation) é inspiração conceitual, não código reutilizável.

### Por que systemd timer e não loop contínuo?
Loop contínuo com heartbeat a cada 5 min chamando Claude = 288 calls/dia = ~67% da cota semanal desperdiçados em "nada aconteceu". Timer oneshot: bash acorda, checa SQLite, se há task pendente → chama Claude, senão → exit. Custo real: 10–30 calls/dia em uso normal.

### ToS e uso não-comercial
Usuário confirmou uso pessoal, não comercial. Zona cinzenta de ToS não é bloqueante.

---

## Status de Implementação

```
[x] Manual de boas práticas       docs/claudeclaw-manual.md
[x] Estado do projeto (este arquivo)

[ ] Setup inicial de repositórios
    [ ] Clonar claude-mem → configurar Docker/local
    [ ] Clonar awesome-claude-code-subagents → .claude/agents/

[ ] Core daemon
    [ ] tasks.db schema (SQLite)
    [ ] Script bash: check_and_run.sh
    [ ] Systemd service + timer files
    [ ] Integração com claude -p

[ ] Memória
    [ ] Integração HTTP com claude-mem (:37777)
    [ ] memory/add após cada task
    [ ] memory/search injetado no prompt

[ ] Segurança
    [ ] config/allowed_commands.yaml
    [ ] Sandbox filesystem (.claudeclaw/workspace/)
    [ ] Secrets em ~/.claudeclaw/secrets/ (chmod 600)

[ ] Observabilidade
    [ ] calls.db para tracking de quota
    [ ] audit_log table
    [ ] health-check.sh (cron 30 min)
    [ ] Alert por email se quota > 250/dia

[ ] Testes
    [ ] BATS tests para security (allowlist)
    [ ] BATS tests para daemon (dry-run)
    [ ] Integration test end-to-end
```

---

## Próximo Passo Imediato

Implementar o loop principal:

```
cron (5 min)
  → check_and_run.sh
    → SELECT * FROM tasks WHERE status='pending' LIMIT 1
    → se vazio: exit 0  (zero custo)
    → se encontrou:
        → buscar memória relevante (claude-mem /search)
        → montar prompt (contexto + task + memória)
        → claude -p "$prompt" --output-format json
        → executar resultado (com --dry-run por padrão)
        → INSERT INTO audit_log ...
        → UPDATE tasks SET status='completed' ...
        → POST claude-mem /memory/add (resultado + aprendizado)
        → exit 0
```

---

## Estrutura de Arquivos Alvo

```
~/.claudeclaw/
├── config.yaml           # Quotas, paths, timeouts
├── secrets/              # API keys (chmod 600, gitignored)
├── workspace/            # Sandbox: agente só escreve aqui
├── memory/               # claude-mem data (gitignored)
│   ├── memory.db         # SQLite FTS5
│   └── chroma/           # Vector DB
├── db/
│   ├── tasks.db          # Tarefas pendentes/concluídas
│   ├── calls.db          # Quota tracking
│   └── audit.db          # Audit log completo
├── logs/
│   ├── agent.jsonl       # Structured logs
│   └── health.log        # Health check results
├── backups/              # Snapshots a cada 6h (14 dias)
└── scripts/
    ├── check_and_run.sh  # Main daemon script
    └── health-check.sh   # Watchdog

.claude/
└── agents/               # awesome-claude-code-subagents

systemd/
├── claudeclaw.service
└── claudeclaw.timer
```

---

## Como Retomar em Nova Sessão

```
Estou construindo ClaudeClaw: agente autônomo usando Claude Max subscription (não API).
Stack: claude -p headless + claude-mem (SQLite FTS5 + Chroma em :37777) + awesome-claude-code-subagents.
Leia docs/claudeclaw-manual.md para boas práticas e docs/claudeclaw-project-state.md para status.
Próximo passo: [descrever o que quer implementar].
```

---

## Recursos

- **Manual de Boas Práticas:** `docs/claudeclaw-manual.md`
- **claude-mem:** https://github.com/Incavenuziano/claude-mem
- **awesome-claude-code-subagents:** https://github.com/Incavenuziano/awesome-claude-code-subagents
- **Hermes (referência):** https://github.com/NousResearch/hermes-agent
- **Claude Code Docs:** https://docs.anthropic.com/en/docs/claude-code
