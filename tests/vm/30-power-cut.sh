#!/usr/bin/env bash
# Power cut during the first boot (R8a): QEMU is killed (SIGKILL) at three points of first-boot
# configuration, then started again on the same disk. The configuration must end up the same as
# after an uninterrupted first boot: same `uci export` (minus the per-boot random ULA prefix and
# DUID), same root hash, no uci-defaults script left.
#   mid:    halfway through the image's longest uci-defaults script, timed from a reference boot;
#           its uci commits are most likely still in the page cache and get lost with the power
#   synced: right after that script, once a VM-only `sync` put its changes on disk; the script is
#           still in /etc/uci-defaults (boot deletes it only after all of them), so it runs again
#           on top of its own result, unless fstools wipes the unfinished overlay first (it does on
#           25.12.6: an overlay not yet marked ready by init's `done` is wiped at the next boot)
#   ready:  1 s after the last init script of the first boot: the next start is a normal boot and
#           must find everything the first boot wrote
# shellcheck disable=SC2016,SC2119 # guest scripts expand in the guest; helper args are optional
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Reference: one uninterrupted first boot
vm_init ref
vm_start
must "reference guest boots" vm_wait_ready
ref_export=$RUN/uci-export.txt
uci_export_normalized >"$ref_export"
ref_root=$(vm_sh "grep '^root:' /etc/shadow")
must "reference uci export read" test -s "$ref_export"
ref_markers=$RUN/markers.tsv

# The image script with the longest before/after marker gap, and half of that gap in seconds
read -r script half < <(awk -F'\t' '
    $2 ~ /^before / { b[substr($2, 8)] = $1 }
    $2 ~ /^after /  { a[substr($2, 7)] = $1 }
    END { best = ""; gap = -1
          for (s in b) if (s in a && a[s] - b[s] > gap) { gap = a[s] - b[s]; best = s }
          if (best != "") printf "%s %.3f\n", best, gap / 2 }' "$ref_markers")
must "reference boot shows the image's uci-defaults script between markers" test -n "${script:-}"
note "longest image script '$script', cut ${half} s after it starts"

cut_and_compare() {
    local point=$1 marker=$2 delay=$3 out
    vm_init "$point"
    vm_start
    out=$(vm_py wait-ready --run "$RUN" --kill-at "$marker" --kill-delay "$delay" --timeout 120) ||
        { check "$point: power cut on marker '$marker'" false; return; }
    note "$point: $(printf '%s' "$out" | tr '\n' ';')"
    vm_start
    check "$point: guest boots again after the cut" vm_wait_ready
    # fstools marks the overlay ready only in init's `done` (START=95); a boot that finds it
    # still pending wipes it and the first boot starts over (both boots print this line)
    if [ "$(tr -d '\r' <"$RUN/console.log" | grep -c 'has not been fully initialized yet')" -ge 2 ]
    then
        note "$point: mount_root found the first boot unfinished, overlay wiped, first boot again"
    fi
    check "$point: no uci-defaults script left" vm_sh '[ -z "$(ls /etc/uci-defaults)" ]'
    uci_export_normalized >"$RUN/uci-export.txt"
    check "$point: uci export equals the uninterrupted boot (R8a)" \
        diff "$ref_export" "$RUN/uci-export.txt"
    check "$point: root hash equals the uninterrupted boot" \
        test "$(vm_sh "grep '^root:' /etc/shadow")" = "$ref_root"
}

cut_and_compare mid "before $script" "$half"
cut_and_compare synced "synced $script" 0
cut_and_compare ready "ready" 1

finish
