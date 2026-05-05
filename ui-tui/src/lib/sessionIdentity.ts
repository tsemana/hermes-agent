// Restored from compiled dist/lib/sessionIdentity.js after the .ts source went
// missing on the hermes-custom branch. Pure formatting helper for the status
// bar identity label: "<persona>: <title> · <model>".

const clean = (value: string | null | undefined): string => (value ?? '').trim()

export function buildIdentityModelLabel(
  model: string | null | undefined,
  persona: string | null | undefined,
  title: string | null | undefined
): string {
  const modelLabel = clean(model)
  const personaLabel = clean(persona)
  const titleLabel = clean(title)
  if (!personaLabel) {
    return modelLabel
  }
  const identity = titleLabel ? `${personaLabel}: ${titleLabel}` : personaLabel
  return modelLabel ? `${identity} · ${modelLabel}` : identity
}
