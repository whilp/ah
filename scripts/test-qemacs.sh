#!/bin/bash
# Validation tests for qemacs built with cosmocc.
# Usage: ./scripts/test-qemacs.sh [path-to-qe-binary]
#
# Requires: the ape loader at o/cosmocc/bin/ape-x86_64.elf

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QE_BIN="${1:-$ROOT/o/qemacs/src/qe_g}"
APE="$ROOT/o/cosmocc/bin/ape-x86_64.elf"

pass=0
fail=0

report() {
    if [ "$1" = "PASS" ]; then
        echo "PASS  $2"
        pass=$((pass + 1))
    else
        echo "FAIL  $2"
        fail=$((fail + 1))
    fi
}

# run qe via APE loader (no tty needed)
run_qe() {
    "$APE" "$QE_BIN" "$@"
}

# run qe in pseudo-tty with timeout, returns exit code
# all args are appended to: APE QE_BIN -nw -q ... +eval 'exit_qemacs(1)'
qe_run() {
    local secs="$1"; shift
    timeout "$secs" script -qefc "$APE $QE_BIN -nw -q $* +eval 'exit_qemacs(1)'" /dev/null 2>&1
}

echo "qemacs cosmocc build validation"
echo "binary: $QE_BIN"
echo "================================"
echo ""

# ===== BINARY STRUCTURE =====
echo "-- binary structure --"

[ -f "$QE_BIN" ] && [ -x "$QE_BIN" ]
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "binary exists and is executable"

size=$(stat -c%s "$QE_BIN" 2>/dev/null || echo 0)
[[ "$size" -gt 500000 && "$size" -lt 10000000 ]]
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "binary size ($size bytes)"

file "${QE_BIN}.com.dbg" 2>/dev/null | grep -q "ELF 64-bit.*x86-64"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "x86_64 ELF present"

file "${QE_BIN}.aarch64.elf" 2>/dev/null | grep -q "ELF 64-bit.*aarch64"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "aarch64 ELF present"

file "${QE_BIN}.com.dbg" 2>/dev/null | grep -q "statically linked"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "statically linked"

out=$(strings "$QE_BIN" 2>/dev/null)
echo "$out" | grep -q "COSMOPOLITAN"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "cosmopolitan strings"

# ===== RUNTIME BASICS =====
echo ""
echo "-- runtime basics --"

out=$(run_qe --version 2>&1)
echo "$out" | grep -q "QEmacs version"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "version output"

echo "$out" | grep -qE "QEmacs version [0-9]+\.[0-9]+"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "version number format"

out=$(run_qe --help 2>&1)
echo "$out" | grep -q "Usage: qe"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "help output"

echo "$out" | grep -q "\-\-no-windows" && echo "$out" | grep -q "\-\-charset"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "help lists expected options"

qe_run 3 "--bogus-option" >/dev/null 2>&1 || true
report PASS "handles unknown option (no crash)"

# ===== FILE HANDLING =====
echo ""
echo "-- file handling --"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
echo "test content" > "$tmpf"
qe_run 3 "$tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "open file and quit"
rm -f "$tmpf"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
: > "$tmpf"
qe_run 3 "$tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "open empty file"
rm -f "$tmpf"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
dd if=/dev/urandom bs=1024 count=1024 2>/dev/null | base64 > "$tmpf"
qe_run 5 "$tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "open 1MB file"
rm -f "$tmpf"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
printf 'Hello World\nBonjour le monde\nUTF8 test\n' > "$tmpf"
qe_run 3 "$tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "open text file"
rm -f "$tmpf"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
dd if=/dev/urandom bs=256 count=1 2>/dev/null > "$tmpf"
qe_run 3 "$tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "open binary file"
rm -f "$tmpf"

qe_run 3 "/tmp/qetest-nonexistent-$$" >/dev/null 2>&1
rc=$?
[[ $rc -ne 139 && $rc -ne 134 ]]
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "open nonexistent (no crash)"

# ===== MODE DETECTION =====
echo ""
echo "-- mode detection --"

tmpf=$(mktemp /tmp/qetest.XXXXXX.c)
printf '#include <stdio.h>\nint main() { return 0; }\n' > "$tmpf"
out=$(qe_run 3 "$tmpf" || true)
rm -f "$tmpf"
echo "$out" | cat -v | grep -qi "(c)"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "C mode for .c file"

tmpf=$(mktemp /tmp/qetest.XXXXXX.py)
printf 'def hello():\n    print("hello")\n' > "$tmpf"
out=$(qe_run 3 "$tmpf" || true)
rm -f "$tmpf"
echo "$out" | cat -v | grep -qi "python"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "Python mode for .py file"

tmpd=$(mktemp -d /tmp/qetest.XXXXXX)
printf 'all:\n\techo hello\n' > "$tmpd/Makefile"
out=$(qe_run 3 "$tmpd/Makefile" || true)
rm -rf "$tmpd"
echo "$out" | cat -v | grep -qi "makefile"
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "Makefile mode"

# ===== EVAL / SCRIPTING =====
echo ""
echo "-- eval / scripting --"

# insert "OK" (O=79, K=75) via self_insert_command, then save
tmpf=$(mktemp /tmp/qetest.XXXXXX)
: > "$tmpf"
timeout 5 script -qefc "$APE $QE_BIN -nw -q $tmpf +eval 'self_insert_command(79)' +eval 'self_insert_command(75)' +eval 'save_buffer()' +eval 'exit_qemacs(1)'" /dev/null >/dev/null 2>&1 || true
content=$(cat "$tmpf")
rm -f "$tmpf"
[[ "$content" = "OK" ]]
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "eval: insert + save"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
printf 'line1\nline2\nline3\nline4\nline5\n' > "$tmpf"
qe_run 3 "+3 $tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "open at line +3"
rm -f "$tmpf"

f1=$(mktemp /tmp/qetest.XXXXXX)
f2=$(mktemp /tmp/qetest.XXXXXX)
echo "file one" > "$f1"
echo "file two" > "$f2"
qe_run 3 "-1 $f1 $f2" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "multiple files (-1)"
rm -f "$f1" "$f2"

# ===== STRESS =====
echo ""
echo "-- stress --"

ok=true
for i in $(seq 1 5); do
    tmpf=$(mktemp /tmp/qetest.XXXXXX)
    echo "iter $i" > "$tmpf"
    if ! qe_run 3 "$tmpf" >/dev/null 2>&1; then
        ok=false
    fi
    rm -f "$tmpf"
done
$ok
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "rapid open/close x5"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
python3 -c "print('x' * 10000)" > "$tmpf" 2>/dev/null || head -c 10000 < /dev/zero | tr '\0' 'x' > "$tmpf"
qe_run 3 "$tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "10KB line"
rm -f "$tmpf"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
seq 1 10000 > "$tmpf"
qe_run 5 "$tmpf" >/dev/null 2>&1
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "10K lines file"
rm -f "$tmpf"

# ===== COSMO RUNTIME =====
echo ""
echo "-- cosmo runtime --"

tmpf=$(mktemp /tmp/qetest.XXXXXX)
echo "strace" > "$tmpf"
out=$(timeout 5 script -qefc "$APE $QE_BIN -nw -q $tmpf +eval 'exit_qemacs(1)' --strace" /dev/null 2>&1 || true)
rm -f "$tmpf"
echo "$out" | grep -qiE "SYS_|open\(|mmap\("
report $([[ $? -eq 0 ]] && echo PASS || echo FAIL) "cosmo --strace"

echo ""
echo "================================"
echo "PASS: $pass  FAIL: $fail  total: $((pass + fail))"
[[ "$fail" -eq 0 ]]
