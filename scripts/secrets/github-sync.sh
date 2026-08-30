#!/usr/bin/env bash
# ============================================================================
#  Pousse kube/urbanlink/secrets.env dans GitHub Secrets
# ----------------------------------------------------------------------------
#   ./scripts/secrets/github-sync.sh             pousse dans le depot courant
#   ./scripts/secrets/github-sync.sh --dry-run   liste sans rien envoyer
#
#  GitHub Secrets devient la source de verite. Attention a une propriete qui
#  change la maniere de travailler : un secret GitHub ne se RELIT PAS. L'API
#  ne permet que l'ecriture ; seul un workflow peut en consommer la valeur.
#  Ce depot local reste donc le seul endroit ou les valeurs sont lisibles --
#  le perdre signifie devoir tout regenerer.
#
#  Les cles vides ne sont pas poussees : un secret GitHub vide masquerait
#  l'absence de valeur au lieu de la signaler.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/../.."
ENV_FILE="kube/urbanlink/secrets.env"
DRY="${1:-}"

[ -f "$ENV_FILE" ] || {
    echo "$ENV_FILE introuvable. Lancer d'abord ./scripts/secrets/bootstrap.sh" >&2
    exit 1
}
command -v gh >/dev/null || { echo "gh (GitHub CLI) est requis." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh n'est pas authentifie : gh auth login" >&2; exit 1; }

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "Depot : $REPO"
[ "$DRY" = "--dry-run" ] && echo "(--dry-run : rien ne sera envoye)"
echo

pushed=0; skipped=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in *[!A-Z0-9_]*) continue;; esac
    if [ -z "$val" ]; then
        printf "  %-32s vide, ignore\n" "$key"
        skipped=$((skipped + 1))
        continue
    fi
    if [ "$DRY" = "--dry-run" ]; then
        printf "  %-32s serait pousse (%d caracteres)\n" "$key" "${#val}"
    else
        # `gh secret set` lit la valeur sur stdin quand --body est absent.
        # La passer en argument l'exposerait dans la table des processus.
        printf '%s' "$val" | gh secret set "$key" --repo "$REPO"
        printf "  %-32s pousse\n" "$key"
    fi
    pushed=$((pushed + 1))
done < "$ENV_FILE"

echo
echo "$pushed pousse(s), $skipped ignore(s) car vide(s)."
[ "$skipped" -gt 0 ] && echo "Les cles vides sont a renseigner dans $ENV_FILE puis a repousser."
exit 0
