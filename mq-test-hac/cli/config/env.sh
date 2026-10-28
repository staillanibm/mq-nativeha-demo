# usage: . config/env.sh [producer|consumer]
# Loads ../.env (variables already set in the environment win), generates
# config/ccdt.json from ccdt.json.template, and points the MQ client at the CCDT.
# With a role, also points it at the keystore of that role.
_c=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

while IFS='=' read -r _k _v; do
  case $_k in ''|\#*) continue;; esac
  [ -n "${!_k+x}" ] || export "$_k=$_v"
done < "$_c/../.env"
unset _k _v

export PATH=$MQ_HOME/bin:$MQ_HOME/samp/bin:$PATH
sed -e "s|\${CHANNEL}|$CHANNEL|g" -e "s|\${MQ_HOST}|$MQ_HOST|g" \
    -e "s|\${MQ_PORT}|$MQ_PORT|g" -e "s|\${QMGR}|$QMGR|g" \
    "$_c/ccdt.json.template" > "$_c/ccdt.json"
export MQCHLLIB=$_c MQCHLTAB=ccdt.json
export MQCLNTCF=$_c/mqclient.ini

if [ -n "${1:-}" ]; then
  [ -f "$_c/tls-$1/key.kdb" ] || { echo "$_c/tls-$1/key.kdb missing: run config/build-keystores.sh" >&2; unset _c; return 1; }
  export MQSSLKEYR=$_c/tls-$1/key
fi
unset _c
