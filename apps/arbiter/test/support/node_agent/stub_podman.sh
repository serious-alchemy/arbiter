#!/bin/sh
D="${STUB_PODMAN_DIR:?}"
sub="$1"
echo "$sub $*" >> "$D/calls"
case "$sub" in
  run)
    printf '%s\n' "$@" > "$D/run.argv"
    env > "$D/run.env"
    mkdir -p "$D/graph"
    : > "$D/graph/config.json"
    prev=""
    for a in "$@"; do
      case "$prev" in
        -e)
          case "$a" in
            *=*) echo "$a" >> "$D/graph/config.json" ;;
            *) eval "echo \"$a=\${$a}\"" >> "$D/graph/config.json" ;;
          esac ;;
        -v)
          case "$a" in
            *:/run/arbiter/secrets.env:*) cat "${a%%:*}" > "$D/secrets.seen" ;;
          esac ;;
      esac
      prev="$a"
    done
    # RW11: stand in for the agent working in its shadow clone: write into the host
    # directory mounted at /work/tree.
    if [ -e "$D/edit" ]; then
      prev=""
      for a in "$@"; do
        if [ "$prev" = "-v" ]; then
          # a run placed through a Worker mounts the shadow at the primary's worktree path
          # (named in `edit_at`), not at /work/tree
          at=$(cat "$D/edit_at" 2>/dev/null || echo /work/tree)
          case "$a" in
            *:/work/tree|*:/work/tree:*|*:"$at"|*:"$at":*)
              h="${a%%:*}"
              # what the shadow was seeded at (RW11), before the "run" edits it
              git -C "$h" rev-parse HEAD > "$D/seeded.head" 2>/dev/null
              echo "edited by the run" > "$h/edited.txt"
              echo '{}' > "$h/.mcp.json"
              # bd-bg87oz: a pass that writes commits. `shadow_script` is run with the shadow
              # clone's path, as the agent's work in it (a rebase, a fix commit).
              if [ -e "$D/shadow_script" ]; then sh "$D/shadow_script" "$h" > "$D/shadow_script.out" 2>&1; fi
              # bd-6ypj2y: an agent that commits in its checkout (the run's shadow clone)
              if [ -e "$D/commit" ]; then
                git -C "$h" add edited.txt
                git -C "$h" -c user.name=agent -c user.email=agent@example.com commit -q -m "agent commit" \
                  && git -C "$h" rev-parse HEAD > "$D/committed.head"
              fi ;;
            *:/work/config|*:/work/config:*)
              h="${a%%:*}"
              mkdir -p "$h/projects/-work-tree"
              echo '{"type":"summary"}' > "$h/projects/-work-tree/s1.jsonl" ;;
          esac
        fi
        prev="$a"
      done
    fi
    # bd-4ic681: a fake agent. `agent_script` runs with the host side of the run's
    # worktree (the shadow clone) and config dir mounts, found by the agent's own dir
    # names, and the container's working directory (`-w`: the primary's worktree path).
    if [ -e "$D/agent_script" ]; then
      wt=""; cf=""; cwd=""; prev=""
      for a in "$@"; do
        case "$prev" in
          -v)
            h="${a%%:*}"
            case "$h" in
              */worktree) wt="$h" ;;
              */config) cf="$h" ;;
            esac ;;
          -w) cwd="$a" ;;
        esac
        prev="$a"
      done
      sh "$D/agent_script" "$wt" "$cf" "$cwd" >> "$D/agent_script.out" 2>&1
    fi
    mode=$(cat "$D/mode" 2>/dev/null || echo lines)
    echo $$ > "$D/run.pid"
    case "$mode" in
      lines)
        n=$(cat "$D/lines" 2>/dev/null || echo 3)
        i=1
        while [ "$i" -le "$n" ]; do echo "line-$i"; i=$((i+1)); done
        exit 0 ;;
      oom) echo "line-1"; echo true > "$D/oom"; exit 137 ;;
      slow)
        echo "line-1"
        while [ ! -e "$D/go" ]; do sleep 0.05; done
        echo "line-2"; echo "line-3"; exit 0 ;;
      hang) echo "line-1"; while [ ! -e "$D/removed" ]; do sleep 0.05; done; exit 137 ;;
      # bd-4p1vui: keeps running across a primary restart and prints after it
      tick)
        echo "line-1"
        while [ ! -e "$D/go" ]; do sleep 0.05; done
        echo "line-2"
        while [ ! -e "$D/removed" ]; do sleep 0.05; done
        exit 137 ;;
      big) head -c "${STUB_BYTES:-1000000}" /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
    esac ;;
  inspect) cat "$D/oom" 2>/dev/null || echo false ;;
  rm) : > "$D/removed"; exit 0 ;;
  # RW12: the reaper lists containers (`ps -a ... --format json`) and pods (`pod ps ...`).
  ps) cat "$D/ps.json" 2>/dev/null || echo '[]'; exit 0 ;;
  pod) cat "$D/pods.json" 2>/dev/null || echo '[]'; exit 0 ;;
  kill) exit 0 ;;
  image) exit 0 ;;
  *) exit 0 ;;
esac
