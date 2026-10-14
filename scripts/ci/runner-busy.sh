#!/bin/bash
# Diz se o runner próprio está rodando testes de interface agora (XCUITest local e do CI na mesma tela
# interferem). Uso local: `scripts/ci/runner-busy.sh && echo "espere" || scripts/ci/test-app.sh YES`.
# Saída 0 = ocupado com test-app; 1 = livre.
set -euo pipefail
pgrep -f "_work/rskeeper/rskeeper.*xcodebuild.*-scheme RSKeeper-Test.*test" > /dev/null 2>&1 && exit 0
pgrep -f "RSKeeperUITests-Runner" > /dev/null 2>&1 && pgrep -f "actions-runner-rskeeper/bin/Runner.Worker" > /dev/null 2>&1 && exit 0
exit 1
