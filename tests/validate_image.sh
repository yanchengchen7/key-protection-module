#!/bin/bash
set -ex
IMAGE_FILE=$1
IMAGE_ENV=$2

count_log=$(strings "$IMAGE_FILE" | grep -o 'ima_appraise=log' | wc -l)
count_enforce=$(strings "$IMAGE_FILE" | grep -o 'ima_appraise=enforce' | wc -l)
count_h_false=$(strings "$IMAGE_FILE" | grep -o 'confidential-space.hardened=false' | wc -l)
count_h_true=$(strings "$IMAGE_FILE" | grep -o 'confidential-space.hardened=true' | wc -l)

echo "Found: ima_appraise=log ($count_log), ima_appraise=enforce ($count_enforce)"
echo "Found: hardened=false ($count_h_false), hardened=true ($count_h_true)"

# Note: strings might match multiple times if the grub.cfg is stored in multiple backup blocks or ext4 journal. 
# We just need to make sure the forbidden ones are EXACTLY 0.
if [ "$IMAGE_ENV" = "debug" ]; then
    if [ "$count_log" -eq 0 ] || [ "$count_enforce" -ne 0 ]; then exit 1; fi
    if [ "$count_h_false" -eq 0 ] || [ "$count_h_true" -ne 0 ]; then exit 1; fi
else
    if [ "$count_enforce" -eq 0 ] || [ "$count_log" -ne 0 ]; then exit 1; fi
    if [ "$count_h_true" -eq 0 ] || [ "$count_h_false" -ne 0 ]; then exit 1; fi
fi
echo "SUCCESS"
