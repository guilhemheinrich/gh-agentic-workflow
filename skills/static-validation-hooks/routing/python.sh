# Routing table — Python (ruff), single-service layout.
# Paste between the BEGIN/END ROUTING TABLE markers in validate-on-edit.sh.
#
# Container prerequisite: the `api` service runs with the project bind-mounted
# at its WORKDIR, and `ruff` is installed inside it (pyproject dev group).
#
# Deliberately absent: mypy. Even `mypy path/to/one.py` re-reads the import
# graph and follows it — 5-20s on a real project. It belongs in CI.
# `ruff check --fix` covers pyflakes/pycodestyle/isort/pyupgrade in ~50ms.

route() {
  case "$REL" in
    # 1. Not validated
    */migrations/*|*_pb2.py|*_pb2_grpc.py|*.generated.py) skip ;;

    # 2. Python sources — format first, then lint what formatting cannot fix.
    #    `ruff format` always exits 0, so it is a `fix`, not a `check`.
    *.py)
      svc api
      fix   ruff format "$F"
      check ruff check --fix --quiet "$F"
      ;;

    # 3. Adjacent config the same container can lint
    *.toml) svc api; check python -c "import tomllib,sys;tomllib.load(open(sys.argv[1],'rb'))" "$F" ;;

    # 4. Anything else warns once, then stays quiet.
    *) ;;
  esac
}
