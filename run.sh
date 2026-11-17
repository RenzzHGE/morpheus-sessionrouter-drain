#!/usr/bin/env bash
# Morpheus SessionRouter fundingAccount drain — PoC run script.
# Only prerequisite: foundry (forge) installed. No other setup.
set -e
cd "$(dirname "$0")"
forge test --fork-url https://mainnet.base.org -vv
