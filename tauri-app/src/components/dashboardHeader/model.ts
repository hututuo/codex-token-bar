export function resolveAccountDisplayName(
  accountDisplayName: string,
  customAccountDisplayName: string,
): string {
  return customAccountDisplayName.trim() || accountDisplayName;
}

export function committedCustomAccountDisplayName(
  displayNameDraft: string,
  currentCustomAccountDisplayName: string,
): string | null {
  const nextName = displayNameDraft.trim();
  if (nextName === currentCustomAccountDisplayName.trim()) {
    return null;
  }
  return nextName;
}

export function shouldCommitDisplayNameOnKey(key: string): boolean {
  return key === "Enter";
}
