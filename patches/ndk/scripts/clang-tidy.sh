#!/bin/sh

BIN_DIR=`dirname "$0"`

i=1
while [ $i -le $# ]; do
    eval arg=\$$i
    if [ "$arg" = "--version" ]; then
        exec "${BIN_DIR}/clang-tidy" "$@"
    fi
    i=`expr $i + 1`
done

usage() {
    cat <<EOF
Environment Variable:
  required: CLANG_CMD={clang|clang++}
  required: TIDY_FILE=<path to the output .tidy file>
  optional: TIDY_TIMEOUT=<seconds>
Usage: clang-tidy.sh <file> <clang-tidy flags> -- <clang/clang++ flags>
EOF
    exit 1
}

INF="$1"

if [ -z "$CLANG_CMD" ]; then
    echo "ERROR: CLANG_CMD environment variable must be set"
    usage
fi
if [ "$CLANG_CMD" != "clang" ] && [ "$CLANG_CMD" != "clang++" ]; then
    echo "ERROR: CLANG_CMD must be 'clang' or 'clang++'"
    usage
fi
if [ -z "$TIDY_FILE" ]; then
    echo "ERROR: TIDY_FILE environment variable must be set"
    usage
fi

LONGDASH=0
i=1
while [ $i -le $# ]; do
    eval arg=\$$i
    if [ "$arg" = "--" ]; then
        LONGDASH=$i
        break
    fi
    i=`expr $i + 1`
done

if [ $LONGDASH -eq 0 ]; then
    echo "ERROR: missing '--' argument"
    usage
fi

CLANG_FLAGS=
j=`expr $LONGDASH + 1`
while [ $j -le $# ]; do
    eval arg=\$$j
    CLANG_FLAGS="$CLANG_FLAGS \"$arg\""
    j=`expr $j + 1`
done

CLANG_FLAGS="$CLANG_FLAGS -E -o /dev/null -MQ $TIDY_FILE -MD -MF $TIDY_FILE.d"

TIDY_CLANG_FLAGS=
i=1
while [ $i -le $# ]; do
    eval arg=\$$i
    TIDY_CLANG_FLAGS="$TIDY_CLANG_FLAGS \"$arg\""
    i=`expr $i + 1`
done

TIDY_STDOUT="${TIDY_FILE}.stdout"
TIDY_STDERR="${TIDY_FILE}.stderr"
CLANG_STDOUT="${TIDY_FILE}.d.stdout"
CLANG_STDERR="${TIDY_FILE}.d.stderr"

OUT_DIR=`dirname "$TIDY_FILE"`
mkdir -p "$OUT_DIR"

eval "${BIN_DIR}/${CLANG_CMD} $INF $CLANG_FLAGS" >"$CLANG_STDOUT" 2>"$CLANG_STDERR" &
CLANG_PID=$!

eval "${BIN_DIR}/clang-tidy $TIDY_CLANG_FLAGS" >"$TIDY_STDOUT" 2>"$TIDY_STDERR" &
TIDY_PID=$!

# Wait for clang
CLANG_RESULT=0
wait $CLANG_PID || CLANG_RESULT=$?

if [ "$CLANG_RESULT" -eq 0 ]; then
    if [ -f "$TIDY_FILE.d" ]; then
        sed -i -e 's:/b/f/w/::' "$TIDY_FILE.d"
    fi
fi

TIDY_RESULT=0
wait $TIDY_PID || TIDY_RESULT=$?

cat "$TIDY_STDOUT"
cat "$TIDY_STDERR" 1>&2

if [ "$TIDY_RESULT" -eq 0 ]; then
    touch "$TIDY_FILE"
    cat "$CLANG_STDOUT"
    cat "$CLANG_STDERR" 1>&2
    TIDY_RESULT=$CLANG_RESULT
else
    rm -f "$TIDY_FILE.d"
fi

rm -f "$TIDY_STDOUT" "$TIDY_STDERR" "$CLANG_STDOUT" "$CLANG_STDERR"

exit $TIDY_RESULT
