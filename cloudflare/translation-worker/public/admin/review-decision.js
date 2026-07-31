export function normalizeReviewTranslation(value) {
  return String(value ?? "").trim().replace(/\s+/gu, " ");
}

export function reviewActionForInput(entry, value) {
  const input = normalizeReviewTranslation(value);
  if (!input) {
    return null;
  }

  const machine = normalizeReviewTranslation(entry.machine_translation);
  if (machine) {
    return input === machine ? "approve" : "edit";
  }

  const approved = normalizeReviewTranslation(entry.approved_translation);
  if (entry.status === "approved" && approved && input === approved) {
    return "approve";
  }

  return "edit";
}

export function nextReviewEntryID(entries, currentID) {
  const currentIndex = entries.findIndex((entry) => entry.id === currentID);
  return currentIndex >= 0
    ? entries[currentIndex + 1]?.id ?? null
    : null;
}

export function applyReviewedEntryToQueue(entries, reviewedEntry, statusFilter) {
  return entries.flatMap((entry) => {
    if (entry.id !== reviewedEntry.id) {
      return [entry];
    }
    if (statusFilter && reviewedEntry.status !== statusFilter) {
      return [];
    }
    return [reviewedEntry];
  });
}

export function reviewReloadURL(currentID, build) {
  const params = new URLSearchParams({
    reviewed: String(currentID),
    ui: String(build),
  });
  return `/admin/?${params.toString()}#review-workspace`;
}

export function reconcileQueueEntry(
  entries,
  refreshedEntry,
  statusFilter,
  kindFilter,
) {
  const currentIndex = entries.findIndex((entry) => entry.id === refreshedEntry.id);
  const matches =
    (!statusFilter || refreshedEntry.status === statusFilter) &&
    (!kindFilter || refreshedEntry.kind === kindFilter);

  if (currentIndex < 0) {
    return { entries, nextID: entries[0]?.id ?? null, matches };
  }

  if (matches) {
    const updatedEntries = [...entries];
    updatedEntries[currentIndex] = refreshedEntry;
    return {
      entries: updatedEntries,
      nextID: refreshedEntry.id,
      matches: true,
    };
  }

  const updatedEntries = entries.filter((entry) => entry.id !== refreshedEntry.id);
  return {
    entries: updatedEntries,
    nextID: updatedEntries[currentIndex]?.id ?? updatedEntries[0]?.id ?? null,
    matches: false,
  };
}

export function selectionAfterReviewedEntry(entries, reviewedID) {
  if (!Number.isSafeInteger(reviewedID) || reviewedID <= 0) {
    return entries[0]?.id ?? null;
  }
  return entries.find((entry) => entry.id < reviewedID)?.id
    ?? entries[0]?.id
    ?? null;
}
