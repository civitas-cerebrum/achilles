#!/bin/bash
IN=$(cat)
if printf '%s' "$IN" | grep -q '"stop_hook_active":true'; then exit 0; fi
printf '%s' '{"decision":"block","reason":"finish first"}'
