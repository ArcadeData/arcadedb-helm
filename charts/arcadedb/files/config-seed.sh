set -e
src="$1"; dst="$2"; shift 2
mkdir -p "$dst"
for f in "$@"; do
  if [ -e "$dst/$f" ]; then
    echo "config-seed: keeping existing $f"
  elif [ -f "$src/$f" ]; then
    cat "$src/$f" > "$dst/.$f.seed"
    mv "$dst/.$f.seed" "$dst/$f"
    echo "config-seed: seeded $f"
  else
    echo "config-seed: $f is not in the image, skipped"
  fi
done
# GREMLIN_PORT (arcadedb.plugins.gremlin.writePortToConfig, #58): the Gremlin
# plugin reads its port only from gremlin-server.yaml, so set the top-level
# port: key there on every start. Every other line is kept as it is.
if [ -n "${GREMLIN_PORT:-}" ]; then
  yaml="$dst/gremlin-server.yaml"
  tmp="$dst/.gremlin-server.yaml.port"
  found=""
  : > "$tmp"
  if [ -f "$yaml" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        port:*|"port :"*|\"port\":*|\'port\':*)
          [ -n "$found" ] || printf 'port: %s\n' "$GREMLIN_PORT" >> "$tmp"
          found=1
          ;;
        *)
          printf '%s\n' "$line" >> "$tmp"
          ;;
      esac
    done < "$yaml"
  fi
  [ -n "$found" ] || printf 'port: %s\n' "$GREMLIN_PORT" >> "$tmp"
  mv "$tmp" "$yaml"
  echo "config-seed: set port: $GREMLIN_PORT in gremlin-server.yaml"
fi
