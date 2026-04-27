# ClaudeClaw: Manual de Boas Práticas

Um agente autônomo robusto e durável executando na sua própria infra com Claude Max. Este manual cobre as práticas essenciais para construir, operacionalizar e evoluir um sistema como esse com confiança.

---

## 1. Princípios Fundadores

**O que são:**
Os três pilares que sustentam todo o design de ClaudeClaw.

| Princípio | Explicação | Por quê importa |
|-----------|-----------|-----------------|
| **Autonomia sem caos** | O agente toma decisões sozinho, mas dentro de guardrails explícitos | Um agente sem limites comete erros exponencialmente; com limites, você dorme tranquilo |
| **Reversibilidade primeiro** | Toda ação tem desfazimento; nada é permanente sem confirmação | Bugs em produção viram lições, não desastres |
| **Quota é o recurso raro** | Chamadas ao Claude (não CPU, não disco) consomem seu Max. Tudo mais é free | Entender isso é a diferença entre rodar 24/7 e ter surpresa cara no fim do mês |

**Como executar:**
- Antes de cada decisão irreversível (deletar arquivo, chamar API externa), o agente pede confirmação ou faz log claro
- O daemon começa com `--dry-run` por padrão; você observa 24h antes de liberar execução real
- Implementar quota budgets: `max_calls_per_day = 288` (teto teórico de 1 call/5min × 24h). Monitorar gastos reais e ajustar
- Toda tarefa registra "what I did, why, outcome" em SQLite. Isso é auditoria + aprendizado

---

## 2. Gestão de Quota Max

**O que é:**
Claude Max oferece 5 janelas de 1 hora (rolling window de 5 horas) + limite semanal. Cada chamada ao modelo consome desse bucket. Bash, cron, SQLite, webhooks = zero custo.

| Padrão | Custo | Observação |
|--------|-------|-----------|
| Heartbeat a cada 5 min chamando Claude | 288 calls/dia = **67% da cota semanal** | ❌ Anti-padrão: setup terrível |
| Cron a cada 5 min checar tarefa em SQLite, DEPOIS chamar Claude se houver trabalho | ~10–20 calls/dia | ✅ Padrão correto |
| Prompt caching com contexto longo (últimas 24h de memória) | Mesmo custo por call, mas menos re-processamento de tokens | ✅ Otimização recomendada |

**Como executar:**
1. **Setup da cron:** Script bash a cada 5 minutos checa `tasks.db` (FTS5 SQLite)
2. **Gatilho inteligente:** Só invoca Claude se:
   - `SELECT * FROM tasks WHERE status='pending'` retorna resultado, OU
   - 3+ horas se passaram desde última execução (anti-stale)
3. **Tracking:** Log cada chamada em `calls.db` com timestamp, tokens estimados, resultado
4. **Alerta:** Se `calls_today > 200`, enviar email ao usuário (não continue cegamente)
5. **Cache de prompt:** Se contexto é > 1024 tokens, use prompt caching para economizar 90% do re-processamento

---

## 3. Memória com claude-mem

**O que é:**
Biblioteca que gerencia memória persistente do agente: FTS5 (busca full-text) + Chroma (embeddings semânticos) + auto-compressão.

| Componente | Função | Por quê necessário |
|-----------|--------|-------------------|
| **FTS5 (SQLite)** | Busca por palavras-chave, logs estruturados | Recuperar fatos específicos rapidamente |
| **Chroma** | Busca semântica: "tarefas relacionadas a emails" encontra "notificações de novo contato" | Reconhecer padrões, não apenas buscar por string exata |
| **Auto-compressão** | Quando memória ultrapassa 10K documentos, LLM resume antigos, apaga resumidos | Manter contexto relevante sem explodir custos |
| **Injeção automática** | Cada prompt inclui os 5 documentos mais relevantes via embedding | Agente "lembra" sem você passar manualmente |

**Como executar:**
1. **Inicializar claude-mem na startup:**
   ```bash
   docker run -d --name claudeclaw-mem \
     -p 37777:37777 \
     -v ~/.claudeclaw/memory:/data \
     incavenuziano/claude-mem
   ```
2. **Estruturar memória em categorias:**
   - `user_preferences` — Gosto da pessoa, idioma, timezone
   - `learned_patterns` — "User sempre pede relatórios às 9am"
   - `error_history` — "API X falhou 3x em 2024-03-15, motivo Y"
   - `task_templates` — Workflows reutilizáveis
3. **Chamar `/memory/add` antes de cada task grande:**
   ```json
   POST http://localhost:37777/memory/add
   { "text": "Task X completed: result Y, took 5min", "category": "task_history" }
   ```
4. **Chamar `/memory/search` dentro do prompt:**
   ```json
   POST http://localhost:37777/memory/search
   { "query": "emails from John", "top_k": 5 }
   ```
5. **Monitorar compressão:** Log em `memory.log` quando resumo acontece (é sinal de que memória está madura)

**Anti-padrão:** Armazenar tudo em prompt context diretamente. Resultado: custos crescem 10x porque contexto fica > 100K tokens.

---

## 4. Skills e Subagents (awesome-claude-code-subagents)

**O que é:**
Biblioteca de ~100 agentes especializados (markdown + YAML) para tarefas específicas: code review, performance analysis, security audit, etc. Cada um é "droppable" no `.claude/agents/`.

| Tipo | Exemplo | Quando usar |
|------|---------|-------------|
| **Especializados** | `code-review.md` para auditar commits | Antes de mergear PRs automaticamente |
| **Sequenciais** | Cadeia de 3 subagents: lint → test → deploy | Pipelines CI/CD custom |
| **Paralelos** | 5 agentes rodando audit de segurança, performance, acessibilidade simultaneamente | Code review completo em 1 chamada |

**Como executar:**
1. **Instalar repositório:**
   ```bash
   git clone https://github.com/Incavenuziano/awesome-claude-code-subagents.git \
     ~/.claude/agents/subagents
   ```
2. **Criar orchestrator em Python/TypeScript** que carrega `.md` e invoca Claude SDK:
   ```python
   with open("~/.claude/agents/subagents/code-review.md") as f:
     system_prompt = f.read()
   
   response = client.messages.create(
     model="claude-opus-4-7",
     max_tokens=4096,
     system=system_prompt,
     messages=[{"role": "user", "content": f"Review:\n{code}"}]
   )
   ```
3. **Integrar com memória:** Cada resultado de subagent vai para `learned_patterns` category em claude-mem
4. **Feedback loop:** Se subagent encontra padrão recorrente, incrementar counter em SQLite; após 3x mesma issue, auto-criar skill customizado

---

## 5. Daemon e Operação Contínua

**O que é:**
ClaudeClaw roda como `systemd` service na sua máquina/servidor, se desperta a cada X minutos, processa tarefas pendentes, volta a dormir.

| Componente | Função | Configuração |
|-----------|--------|--------------|
| **Systemd service** | Inicia na boot, reinicia se crash, limita recursos | `systemd/claudeclaw.service` |
| **Timer (cron equiv)** | A cada 5 min, chama `/usr/local/bin/claudeclaw run` | `systemd/claudeclaw.timer` |
| **Logs** | Journalctl captura stdout/stderr | `journalctl -u claudeclaw -f` para live tail |
| **Watchdog** | Script que valida "agente vivo?" a cada 30 min | Envia alert se heartbeat ausente > 1h |

**Como executar:**
1. **Criar unit file** `~/.config/systemd/user/claudeclaw.service`:
   ```ini
   [Unit]
   Description=ClaudeClaw Autonomous Agent
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   ExecStart=/usr/local/bin/claudeclaw run
   StandardOutput=journal
   StandardError=journal
   SyslogIdentifier=claudeclaw
   ```

2. **Criar timer** `~/.config/systemd/user/claudeclaw.timer`:
   ```ini
   [Unit]
   Description=ClaudeClaw Execution Timer
   Requires=claudeclaw.service

   [Timer]
   OnBootSec=2min
   OnUnitActiveSec=5min
   AccuracySec=1s
   ```

3. **Enable e start:**
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now claudeclaw.timer
   journalctl --user -u claudeclaw -f  # Watch it
   ```

4. **Estrutura do `run` script:**
   ```bash
   #!/bin/bash
   # 1. Check tasks in SQLite
   # 2. If found, prepare context (memória + últimas 24h logs)
   # 3. Call Claude via MCP or Claude Code
   # 4. Execute result (com --dry-run flag por padrão)
   # 5. Log outcome + update memory
   # 6. Exit (systemd reinicia em 5 min)
   ```

---

## 6. Segurança: Guardrails e Confinamento

**O que é:**
Um agente autônomo que pode chamar APIs, escrever arquivos, invocar comandos deve estar **confinado** a um escopo claro. Sem isso, falha de segurança = agente fazendo dano sozinho por horas.

| Guardrail | Implementação | Impacto |
|-----------|---------------|--------|
| **Allowlist de commands** | `config/allowed_commands.yaml` lista exatamente o que agente pode rodar: `git`, `python`, `curl` (para APIs específicas) | Falha de memória do agente não permite `rm -rf /` |
| **Sandbox filesystem** | Agente só pode acessar `~/.claudeclaw/workspace/` + explicitamente whitelisted paths (ex: `/data/uploads`) | Proteção contra leitura acidental de `~/.ssh/` |
| **API key isolation** | Keys armazenadas em `~/.claudeclaw/secrets/` com permissões 600; injected via env vars, não em prompts | Keys não vazam em logs ou memória |
| **Rate limits internos** | Por-endpoint: máx 10 calls/min para APIs externas | Protege contra DoS de API se agente entra loop |
| **Audit trail** | Cada execução é logged: timestamp, comando, usuário, output (primeiros 1000 chars) | Investigar o que deu errado |

**Como executar:**
1. **Criar `config/allowed_commands.yaml`:**
   ```yaml
   allowed:
     - command: git
       args: [clone, pull, push, commit, checkout]
       max_concurrent: 2
     - command: curl
       args: []  # Qualquer arg, mas vetted por URL allowlist
       url_allowlist:
         - https://api.github.com/*
         - https://api.openweather.com/*
     - command: python
       scripts_only: true  # Apenas scripts pré-aprovados em ~/.claudeclaw/scripts/
   ```

2. **Validar antes de executar:**
   ```bash
   validate_command() {
     local cmd="$1"
     grep -q "^[[:space:]]*- command: $cmd" config/allowed_commands.yaml || \
       { echo "DENIED: $cmd not whitelisted"; return 1; }
   }
   ```

3. **Secrets management:**
   ```bash
   # Store once
   echo "sk-..." > ~/.claudeclaw/secrets/openai_key
   chmod 600 ~/.claudeclaw/secrets/openai_key
   
   # Inject at runtime
   export OPENAI_API_KEY=$(cat ~/.claudeclaw/secrets/openai_key)
   # Never echo $OPENAI_API_KEY in logs!
   ```

4. **Auditoria:**
   ```sql
   CREATE TABLE audit_log (
     id INTEGER PRIMARY KEY,
     timestamp TEXT,
     command TEXT,
     args TEXT,
     exit_code INTEGER,
     output_head TEXT,
     duration_ms INTEGER
   );
   ```

---

## 7. Reversibilidade: Desfazimento por Design

**O que é:**
Toda mudança significativa deve ser revertível em < 5 minutos sem perda de dados. Não há "oops, deletei production" em ClaudeClaw.

| Operação | Reversível? | Como |
|-----------|------------|------|
| Tarefa executada | ✅ Sim | Log + memória permitem replay com `--undo` flag |
| Arquivo escrito | ✅ Sim | Git + versioning automático antes de write |
| Arquivo deletado | ✅ Sim | Move para `trash/` com timestamp, não rm direto |
| Banco de dados alterado | ✅ Sim | Backup automático a cada 6h; restore via SQL dump |
| API chamada com efeito colateral | ⚠️ Parcial | Registrar ID da operação, chamar cancel/undo endpoint se existir |

**Como executar:**
1. **Git auto-commit antes de write:**
   ```bash
   write_safe() {
     local file="$1" content="$2"
     [ -f "$file" ] && git add "$file" && git commit -m "backup: $file before write"
     echo "$content" > "$file"
     git add "$file"
     git commit -m "update: $file"
   }
   ```

2. **Trash folder:**
   ```bash
   delete_safe() {
     local file="$1" timestamp=$(date +%s)
     mkdir -p ~/.claudeclaw/trash
     mv "$file" ~/.claudeclaw/trash/"${file##*/}.$timestamp"
     echo "Moved to trash: ~/.claudeclaw/trash/${file##*/}.$timestamp"
   }
   ```

3. **Database snapshots:**
   ```bash
   # Cron job a cada 6h
   sqlite3 ~/.claudeclaw/memory/memory.db ".dump" | \
     gzip > ~/.claudeclaw/backups/memory-$(date +%Y%m%d-%H%M%S).sql.gz
   # Keep 14 days
   find ~/.claudeclaw/backups -name "memory-*.sql.gz" -mtime +14 -delete
   ```

4. **Dry-run por padrão:**
   ```bash
   # Sempre rodar com --dry-run=true, depois rever, depois --dry-run=false
   /usr/local/bin/claudeclaw run --dry-run=true
   # Review output
   /usr/local/bin/claudeclaw run --dry-run=false --confirm-id=<hash>
   ```

---

## 8. Observabilidade: Sabendo o Que Está Acontecendo

**O que é:**
Sem observabilidade, o agente virou black box. Você precisa saber: está vivo? Está fazendo ooque? Está preso em loop? Quanto quota gastou?

| Métrica | Ferramenta | Frequência |
|---------|-----------|-----------|
| **Heartbeat** | Cron log line com timestamp | A cada 5 min |
| **Quota spent** | Count de calls em `calls.db` | A cada execução |
| **Task success rate** | `SELECT COUNT(*) FROM tasks WHERE status='completed'` / total | Hourly |
| **Memory size** | `du -sh ~/.claudeclaw/memory/` | Daily |
| **Error rate** | Grep "ERROR" em journalctl | Realtime |

**Como executar:**
1. **Dashboard (simples):** Python Flask que serve `/metrics`:
   ```python
   @app.route('/metrics')
   def metrics():
       calls_today = db.execute(
           "SELECT COUNT(*) FROM calls WHERE DATE(timestamp)=DATE('now')"
       ).fetchone()[0]
       tasks_pending = db.execute(
           "SELECT COUNT(*) FROM tasks WHERE status='pending'"
       ).fetchone()[0]
       memory_size = subprocess.run(['du', '-sb', MEMORY_DIR], 
                                   capture_output=True).stdout.decode().split()[0]
       
       return {
           'calls_today': calls_today,
           'calls_remaining': 300 - calls_today,  # Budget
           'tasks_pending': tasks_pending,
           'memory_size_mb': int(memory_size) / 1024 / 1024,
           'last_execution': db.execute("SELECT MAX(timestamp) FROM tasks").fetchone()[0]
       }
   ```

2. **Alertas:**
   ```bash
   # Cron a cada 30 min
   calls=$(sqlite3 ~/.claudeclaw/calls.db \
     "SELECT COUNT(*) FROM calls WHERE DATE(timestamp)=DATE('now')")
   if [ "$calls" -gt 250 ]; then
     mail -s "ClaudeClaw: High quota usage ($calls/300 today)" "$USER" \
       <<< "Consider investigating if loops are happening."
   fi
   ```

3. **Structured logging:**
   ```bash
   log_event() {
     local level="$1" message="$2"
     local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
     echo "{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"message\":\"$message\"}" \
       >> ~/.claudeclaw/logs/agent.jsonl
   }
   ```

---

## 9. Testes: Garantindo Confiança

**O que é:**
Código que valida o agente funciona como esperado. Importante porque agente autônomo em produção = mais um motivo para ter testes rigorosos.

| Tipo | Exemplo | Executar |
|------|---------|----------|
| **Unit** | Função `_validate_command()` rejeita comando ilegal | `bats tests/` |
| **Integration** | Tarefa começa → código executado → resultado logado → memória atualizada | Dentro do `run` script com `--dry-run=true` |
| **Security** | Tentativa de read `/etc/passwd` é bloqueada | Manual: `echo 'cat /etc/passwd' \| claudeclaw run` → must fail |
| **Quota** | Simular 300 calls, verificar que nó-chama depois | Mock em `tests/` |

**Como executar:**
1. **BATS framework** (Bash Automated Testing System) — vendored em `tests/bats/`:
   ```bash
   # tests/core/security.bats
   @test "deny reading /etc/passwd" {
     run claudeclaw execute "cat /etc/passwd"
     assert_failure
     assert_output --partial "DENIED"
   }
   ```

2. **Run tests localmente:**
   ```bash
   ./tests/bats/bats-core/bin/bats tests/core/
   ```

3. **Integration test dentro de `run`:**
   ```bash
   if [ "$DRY_RUN" = "true" ]; then
     # Simular execução, log tudo, mas não fazer mudanças reais
     log_event "INFO" "DRY RUN: Would execute '$cmd'"
     # Validar que memory.add seria chamado
     # Validar que git commit seria feito
     # Não fazer nenhum deles
   fi
   ```

---

## 10. Versionamento e Configuração

**O que é:**
ClaudeClaw evolui: novos skills, mudanças em quotas, ajustes de memória. Sem versionamento claro, você não sabe qual config estava ativa quando algo deu errado.

| Arquivo | Função | Versionado? |
|---------|--------|------------|
| `.claudeclaw/config.yaml` | Quotas, paths, timeouts | ✅ Em git |
| `.claudeclaw/skills/` | Subagents customizados | ✅ Em git |
| `.claudeclaw/secrets/` | API keys | ❌ Gitignored |
| `.claudeclaw/memory/` | Vector DB + FTS | ❌ Gitignored, backups só |
| `.claudeclaw/.version` | Release version + build hash | ✅ Em git |

**Como executar:**
1. **Config YAML com versioning:**
   ```yaml
   # ~/.claudeclaw/config.yaml
   version: "0.1.0"
   build_sha: "abc1234"  # Git hash do último build
   
   quota:
     max_daily_calls: 300
     max_per_window: 20  # 5 min rolling
     enable_caching: true
   
   memory:
     type: "claude-mem"
     endpoint: "http://localhost:37777"
     auto_compress_after: 10000  # docs
     retention_days: 90
   
   security:
     sandbox_path: "/home/$USER/.claudeclaw/workspace"
     allowed_commands_file: "./config/allowed_commands.yaml"
   
   daemon:
     check_interval_seconds: 300
     watchdog_interval_seconds: 1800
   ```

2. **Tracking de mudanças:**
   ```bash
   # Antes de aplicar nova config
   git add .claudeclaw/config.yaml
   git commit -m "config: increase quota limit to 400/day for testing"
   git log -1 --oneline  # a1b2c3d config: increase quota...
   
   # Depois, se algo deu errado:
   git show a1b2c3d  # Ver exatamente oq mudou
   ```

3. **Versionamento de skills:**
   ```
   .claudeclaw/skills/
   ├── code-review/
   │   ├── v1/
   │   │   └── prompt.md
   │   └── v2/
   │       └── prompt.md
   ├── security-audit/
   │   └── v1/
   │       └── prompt.md
   ```
   Config aponta: `code_review_skill: v2` → sempre reproduzível

---

## 11. Disciplina de Evolução: Crescimento Controlado

**O que é:**
Com o tempo, agente aprende, acumula skills, memória cresce. Sem disciplina, vira unmaintainable. Com disciplina, melhora exponencial e controlada.

| Prática | Como | Frequência |
|---------|------|-----------|
| **Skill review** | A cada 2 semanas, revisar skills mais usados; consolidar duplicatas; remover unused | Bi-semanal |
| **Memory audit** | Conferir se memória tem garbage (docs sem relevância). Pode deletar manualmente ou via script | Monthly |
| **Quota trending** | Gráfico: calls/day últimos 30 dias. Se crescendo, investigar loops | Semanal |
| **Incident postmortem** | Se error rate > 5%, fazer postmortem: oq causou, como prevenir | Quando ocorrer |

**Como executar:**
1. **Skill review checklist:**
   ```bash
   # Cron a cada 2 semanas
   sqlite3 ~/.claudeclaw/memory/memory.db \
     "SELECT skill, COUNT(*) as uses FROM executions 
      WHERE timestamp > datetime('now', '-14 days')
      GROUP BY skill
      ORDER BY uses DESC"
   # Revisar top 10 skills; se uses < 2, marcar para deprecation
   ```

2. **Memory cleanup (manual, com supervisão):**
   ```bash
   # Encontrar documentos antigos/irrelevantes
   sqlite3 ~/.claudeclaw/memory/memory.db \
     "SELECT id, text, embedding_dist FROM memories
      WHERE timestamp < datetime('now', '-60 days')
      AND embedding_dist > 0.8  -- Low relevance (cosine > 0.8 = low sim)
      LIMIT 10"
   
   # Revisar manualmente, deletar se confortável
   # Ou: deixar para auto-compressão fazer
   ```

3. **Quota analysis:**
   ```python
   import sqlite3
   from datetime import datetime, timedelta
   
   conn = sqlite3.connect('~/.claudeclaw/calls.db')
   today = datetime.now()
   
   for i in range(30):
       d = today - timedelta(days=i)
       count = conn.execute(
           "SELECT COUNT(*) FROM calls WHERE DATE(timestamp)=?",
           (d.date(),)
       ).fetchone()[0]
       print(f"{d.date()}: {count} calls")
   ```

---

## 12. Resposta a Incidentes: Quando Algo Dá Errado

**O que é:**
Apesar de tudo, problemas acontecem. Agente trava, entrada de memória fica corrupta, API externo falha. Você precisa de playbook.

| Cenário | Sintoma | Ação imediata | Investigação |
|---------|---------|--------------|--------------|
| **Agent offline** | Sem log há > 1h | 1. `systemctl --user restart claudeclaw.timer` 2. Verificar `journalctl` | Ver exit code, crashes de mem? |
| **Quota explosion** | 200+ calls em 1 hora | 1. `systemctl --user stop claudeclaw.timer` 2. Impedir execução | Ver logs: foi chamada Claude em loop? |
| **Memory corruption** | Query em `memory.db` falha | 1. Backups estão OK? 2. Restaurar de 6h atrás | Replay de qual tarefa introduziu corrupção? |
| **Security breach** | Comando não-whitelisted executado | 1. Kill agent (`stop claudeclaw.timer`) 2. Backup de dados 3. Review logs | Prompt injection? Falha em parsing? |

**Como executar:**

1. **Monitoring script** (cron a cada 30 min):
   ```bash
   #!/bin/bash
   # ~/.claudeclaw/scripts/health-check.sh
   
   LAST_RUN=$(journalctl --user -u claudeclaw -n 1 --format='%(realtime)' | 
              date -f - +%s 2>/dev/null || echo 0)
   NOW=$(date +%s)
   DIFF=$((NOW - LAST_RUN))
   
   if [ "$DIFF" -gt 3600 ]; then
     echo "ALERT: Agent offline > 1h" | mail -s "ClaudeClaw Alert" "$USER"
     # Try restart
     systemctl --user restart claudeclaw.timer
   fi
   
   # Check calls today
   CALLS=$(sqlite3 ~/.claudeclaw/calls.db \
     "SELECT COUNT(*) FROM calls WHERE DATE(timestamp)=DATE('now')")
   if [ "$CALLS" -gt 280 ]; then
     echo "ALERT: High quota usage ($CALLS/300)" | mail -s "ClaudeClaw Alert" "$USER"
   fi
   
   # Check memory
   if ! sqlite3 ~/.claudeclaw/memory/memory.db "SELECT COUNT(*) FROM memories" >/dev/null 2>&1; then
     echo "ALERT: Memory DB corrupted" | mail -s "ClaudeClaw CRITICAL" "$USER"
   fi
   ```

2. **Incident log:**
   ```sql
   CREATE TABLE IF NOT EXISTS incidents (
     id INTEGER PRIMARY KEY,
     timestamp TEXT,
     severity TEXT,  -- CRITICAL, HIGH, MEDIUM, LOW
     title TEXT,
     description TEXT,
     actions_taken TEXT,
     resolution_time_minutes INTEGER,
     root_cause TEXT
   );
   
   -- Depois de resolver, logar:
   INSERT INTO incidents VALUES (
     NULL,
     datetime('now'),
     'HIGH',
     'Agent loop on email sync',
     'Called email API 47x in 10 minutes',
     '1. Stopped timer 2. Checked logs 3. Found malformed filter',
     15,
     'Typo in memory filter caused infinite retry'
   );
   ```

3. **Recovery playbook** (por tipo de falha):
   ```markdown
   ## Recovery: Memory DB Corrupted
   1. Stop agent: `systemctl --user stop claudeclaw.timer`
   2. Find latest backup: `ls -t ~/.claudeclaw/backups/memory-*.sql.gz | head -1`
   3. Restore: `gunzip < backup | sqlite3 ~/.claudeclaw/memory/memory.db`
   4. Validate: `sqlite3 ~/.claudeclaw/memory/memory.db "PRAGMA integrity_check"`
   5. Resume: `systemctl --user start claudeclaw.timer`
   6. Postmortem: O que corrupted a DB? Bug em escrita, falha de disk, ...?
   ```

---

## Resumo: Checklist de Preparação

Antes de ligar o daemon em produção:

- [ ] Quota budgets definidos em `config.yaml` e monitorados
- [ ] claude-mem rodando, SQLite FTS5 + Chroma configurados
- [ ] Allowlist de commands criado e testado (deny por padrão)
- [ ] Systemd service + timer criados e testados
- [ ] Dry-run completo: agente executa sem fazer mudanças reais
- [ ] Reversibilidade testada: deletar arquivo → recuperar de git/trash
- [ ] Observabilidade online: logs, alerts, dashboard
- [ ] Backup strategy em lugar: a cada 6h, retenção 14 dias
- [ ] BATS tests cobrindo security + integração
- [ ] Postmortem playbook escrito e compartilhado
- [ ] 24h observação com `--dry-run=true` antes de liberar execução real

**Depois que tudo passa:**

```bash
# Commit e push
git add .
git commit -m "feat: ClaudeClaw production-ready setup"
git push origin claude/autonomous-agent-server-UIVpl

# Deploy: apenas após revisão humana
systemctl --user enable --now claudeclaw.timer

# Watch
journalctl --user -u claudeclaw -f
```

---

## Recursos Adicionais

- **claude-mem:** https://github.com/Incavenuziano/claude-mem
- **awesome-claude-code-subagents:** https://github.com/Incavenuziano/awesome-claude-code-subagents
- **Claude Code Docs:** https://claude.ai/code (headless + integrations)
- **BATS Testing:** https://github.com/bats-core/bats-core
- **Systemd Docs:** https://systemd.io

**Boa sorte construindo ClaudeClaw. O agente autônomo que respeita quotas, não vai em loops, é observável e é reversível. 🍌**
