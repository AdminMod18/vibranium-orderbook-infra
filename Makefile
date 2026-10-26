# Atajos opcionales. Todo se puede ejecutar directamente con los scripts de scripts/ (en Windows, Git Bash no trae make).
.PHONY: validate up image deploy smoke chaos down all
validate: ; scripts/validate.sh
up:       ; scripts/kind-up.sh
image:    ; scripts/build-image.sh
deploy:   ; scripts/deploy.sh local
smoke:    ; scripts/smoke.sh
chaos:    ; scripts/chaos.sh kill-pod && scripts/chaos.sh postgres-down
down:     ; scripts/kind-down.sh
all: up image deploy smoke chaos
