import {
  normalizeReviewTranslation,
  reconcileQueueEntry,
  reviewReloadURL,
  reviewActionForInput,
  selectionAfterReviewedEntry,
} from "./review-decision.js";

const ADMIN_UI_BUILD = "2026.07.29.1";

const elements = {
  sessionEmail: document.querySelector("#session-email"),
  pending: document.querySelector("#summary-pending"),
  approved: document.querySelector("#summary-approved"),
  edited: document.querySelector("#summary-edited"),
  dictionary: document.querySelector("#summary-dictionary"),
  release: document.querySelector("#summary-release"),
  releaseDescription: document.querySelector("#release-description"),
  releaseNote: document.querySelector("#release-note-input"),
  publish: document.querySelector("#publish-button"),
  releaseActionState: document.querySelector("#release-action-state"),
  releaseList: document.querySelector("#release-list"),
  releaseComparison: document.querySelector("#release-comparison"),
  releaseComparisonTitle: document.querySelector("#release-comparison-title"),
  releaseComparisonSummary: document.querySelector("#release-comparison-summary"),
  releaseComparisonList: document.querySelector("#release-comparison-list"),
  closeComparison: document.querySelector("#close-comparison-button"),
  retryFailed: document.querySelector("#retry-failed-button"),
  aiProgress: document.querySelector("#ai-progress"),
  aiProgressCount: document.querySelector("#ai-progress-count"),
  aiProgressDetail: document.querySelector("#ai-progress-detail"),
  aiAllowanceProgress: document.querySelector("#ai-allowance-progress"),
  aiAllowanceCount: document.querySelector("#ai-allowance-count"),
  aiAllowanceDetail: document.querySelector("#ai-allowance-detail"),
  resetAIAllowance: document.querySelector("#reset-ai-allowance-button"),
  error: document.querySelector("#error-banner"),
  refresh: document.querySelector("#refresh-button"),
  filterForm: document.querySelector("#filter-form"),
  search: document.querySelector("#search-input"),
  status: document.querySelector("#status-filter"),
  kind: document.querySelector("#kind-filter"),
  queueStatus: document.querySelector("#queue-status"),
  list: document.querySelector("#translation-list"),
  loadMore: document.querySelector("#load-more-button"),
  emptyDetail: document.querySelector("#empty-detail"),
  detailContent: document.querySelector("#detail-content"),
  detailStatus: document.querySelector("#detail-status"),
  detailKind: document.querySelector("#detail-kind"),
  detailOrigin: document.querySelector("#detail-origin"),
  detailSource: document.querySelector("#detail-source"),
  detailNormalized: document.querySelector("#detail-normalized"),
  detailMachine: document.querySelector("#detail-machine"),
  detailApproved: document.querySelector("#detail-approved"),
  similar: document.querySelector("#similar-list"),
  copySource: document.querySelector("#copy-source-button"),
  reviewSource: document.querySelector("#review-source"),
  translationInput: document.querySelector("#translation-input"),
  translationLength: document.querySelector("#translation-length"),
  approve: document.querySelector("#approve-button"),
  reject: document.querySelector("#reject-button"),
  deferDuration: document.querySelector("#defer-duration"),
  defer: document.querySelector("#defer-button"),
  saveState: document.querySelector("#save-state"),
  metadata: document.querySelector("#entry-metadata"),
  aliases: document.querySelector("#alias-list"),
  revisionCount: document.querySelector("#revision-count"),
  revisions: document.querySelector("#revision-list"),
  toast: document.querySelector("#toast"),
};

const state = {
  translations: [],
  nextCursor: null,
  selectedID: null,
  detail: null,
  summary: null,
  releases: [],
  releaseComparison: null,
  aiRetryStatus: null,
  aiUsage: null,
  releasing: false,
  retrying: false,
  resettingAIAllowance: false,
  loading: false,
  saving: false,
  searchTimer: null,
  aiPollTimer: null,
  aiRetryRemaining: null,
  listLoadGeneration: 0,
  reviewedID: Number.parseInt(
    new URLSearchParams(window.location.search).get("reviewed") ?? "",
    10,
  ),
};

function setText(element, value, fallback = "—") {
  element.textContent =
    value === null || value === undefined || value === "" ? fallback : String(value);
}

function formatDate(value) {
  if (!value) {
    return "—";
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? String(value)
    : new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(date);
}

function showError(message) {
  elements.error.textContent = message;
  elements.error.hidden = false;
}

function clearError() {
  elements.error.hidden = true;
  elements.error.textContent = "";
}

let toastTimer;
function showToast(message) {
  clearTimeout(toastTimer);
  elements.toast.textContent = message;
  elements.toast.hidden = false;
  toastTimer = setTimeout(() => {
    elements.toast.hidden = true;
  }, 3200);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    cache: "no-store",
    credentials: "same-origin",
    headers: {
      accept: "application/json",
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...options.headers,
    },
    ...options,
  });
  const contentType = response.headers.get("content-type") ?? "";
  const body = contentType.includes("application/json")
    ? await response.json()
    : null;

  if (!response.ok) {
    const error = new Error(body?.error ?? `Request failed with ${response.status}.`);
    error.status = response.status;
    throw error;
  }
  return body;
}

function statusMap(summary) {
  return new Map(summary.statuses.map((item) => [item.status, item.count]));
}

function populateKinds(kinds) {
  const selected = elements.kind.value;
  elements.kind.replaceChildren();
  const all = document.createElement("option");
  all.value = "";
  all.textContent = "All kinds";
  elements.kind.append(all);

  for (const item of kinds) {
    const option = document.createElement("option");
    option.value = item.kind;
    option.textContent = `${item.kind} (${item.count})`;
    elements.kind.append(option);
  }
  elements.kind.value = selected;
}

function renderSummary(summary) {
  state.summary = summary;
  const statuses = statusMap(summary);
  setText(elements.pending, statuses.get("pending") ?? 0);
  setText(elements.approved, statuses.get("approved") ?? 0);
  setText(elements.edited, statuses.get("edited") ?? 0);

  if (summary.dictionary?.dirty) {
    elements.dictionary.textContent = "Changes ready";
  } else {
    elements.dictionary.textContent = "Up to date";
  }

  if (summary.currentRelease) {
    elements.release.textContent =
      `Published v${summary.currentRelease.version} · ${summary.currentRelease.entry_count} entries`;
  } else {
    elements.release.textContent = "No R2 release published yet";
  }
  populateKinds(summary.kinds);
  renderReleaseControls();
  if (state.aiRetryStatus) {
    renderAIRetryStatus(state.aiRetryStatus);
  }
}

function scheduleAIRetryPoll(active) {
  clearTimeout(state.aiPollTimer);
  state.aiPollTimer = null;
  if (active) {
    state.aiPollTimer = setTimeout(() => {
      void loadAIRetryStatus();
    }, 15000);
  }
}

function failedEntryCount() {
  return state.summary
    ? statusMap(state.summary).get("failed") ?? 0
    : 0;
}

function renderAIRetryStatus(status) {
  const previousRemaining = state.aiRetryRemaining;
  state.aiRetryStatus = status;
  const job = status.job;
  const failedEntries = failedEntryCount();

  if (!job || job.total === 0) {
    state.aiRetryRemaining = 0;
    elements.retryFailed.disabled = state.retrying || failedEntries === 0;
    elements.retryFailed.textContent = state.retrying
      ? "Queuing retries…"
      : failedEntries > 0
        ? `Retry ${failedEntries} failed`
        : "No failed entries";
    elements.aiProgress.max = 1;
    elements.aiProgress.value = 0;
    elements.aiProgressCount.textContent =
      failedEntries > 0 ? `${failedEntries} failed` : "Queue is clear";
    elements.aiProgressDetail.textContent =
      failedEntries > 0
        ? "Failed entries are waiting for you to start a retry job."
        : "There are no failed or queued AI translations.";
    scheduleAIRetryPoll(false);
    return;
  }

  const remaining = Math.max(0, job.remaining);
  state.aiRetryRemaining = remaining;
  elements.retryFailed.disabled =
    state.retrying || remaining > 0 || failedEntries === 0;
  elements.retryFailed.textContent = state.retrying
    ? "Queuing retries…"
    : remaining > 0
      ? "Retry in progress"
      : failedEntries > 0
        ? `Retry ${failedEntries} failed`
        : "No failed entries";
  elements.aiProgress.max = Math.max(job.total, 1);
  elements.aiProgress.value = Math.min(job.completed, job.total);
  elements.aiProgressCount.textContent =
    `${job.completed} / ${job.total} complete`;
  elements.aiProgressDetail.textContent =
    `${job.processing} processing · ${job.pending} pending`;
  scheduleAIRetryPoll(remaining > 0);

  if (previousRemaining > 0 && remaining === 0) {
    void loadSummary();
  }
}

async function loadAIRetryStatus() {
  try {
    renderAIRetryStatus(await api("/admin/api/ai-retries"));
  } catch (error) {
    scheduleAIRetryPoll(false);
    showError(error.message);
  }
}

async function retryFailedTranslations() {
  const failedEntries = failedEntryCount();
  if (
    state.retrying ||
    failedEntries === 0 ||
    !window.confirm(
      `Queue ${failedEntries} failed translations for Workers AI retry? ` +
      "Daily AI request and character limits will still apply.",
    )
  ) {
    return;
  }

  clearError();
  state.retrying = true;
  renderAIRetryStatus(state.aiRetryStatus);
  try {
    const status = await api("/admin/api/ai-retries", { method: "POST" });
    renderAIRetryStatus(status);
    await Promise.all([
      loadSummary(),
      loadList({ preserveSelection: true }),
    ]);
    showToast(`${status.job?.total ?? 0} failed translations queued for retry.`);
  } catch (error) {
    showError(error.message);
  } finally {
    state.retrying = false;
    if (state.aiRetryStatus) {
      renderAIRetryStatus(state.aiRetryStatus);
    }
  }
}

function renderAIUsage(usage) {
  state.aiUsage = usage;
  const number = new Intl.NumberFormat();
  elements.aiAllowanceProgress.max = Math.max(usage.requestLimit, 1);
  elements.aiAllowanceProgress.value = Math.min(
    usage.requests,
    usage.requestLimit,
  );
  elements.aiAllowanceCount.textContent =
    `${number.format(usage.requests)} / ${number.format(usage.requestLimit)} requests`;
  elements.aiAllowanceDetail.textContent =
    `${number.format(usage.characters)} / ${number.format(usage.characterLimit)} characters · ` +
    `${number.format(usage.failures)} model failure attempts · ` +
    `${number.format(usage.deferredEntries)} capacity-deferred entries · ` +
    `automatic reset ${formatDate(usage.resetsAt)}`;
  elements.resetAIAllowance.disabled =
    state.resettingAIAllowance ||
    (
      usage.requests === 0 &&
      usage.characters === 0 &&
      usage.deferredEntries === 0
    );
  elements.resetAIAllowance.textContent = state.resettingAIAllowance
    ? "Resetting allowance…"
    : "Reset daily allowance";
}

async function loadAIUsage() {
  try {
    const result = await api("/admin/api/ai-usage");
    renderAIUsage(result.usage);
  } catch (error) {
    showError(error.message);
  }
}

async function resetAIAllowance() {
  if (state.resettingAIAllowance || !state.aiUsage) {
    return;
  }
  const usage = state.aiUsage;
  if (
    !window.confirm(
      `Reset today’s application AI allowance after ` +
      `${usage.requests} requests and ${usage.characters} characters? ` +
      `${usage.deferredEntries} capacity-deferred entries will become eligible to resume. ` +
      "This does not reset Cloudflare account-level usage or billing.",
    )
  ) {
    return;
  }

  clearError();
  state.resettingAIAllowance = true;
  renderAIUsage(usage);
  try {
    const result = await api("/admin/api/ai-usage/reset", { method: "POST" });
    renderAIUsage(result.usage);
    await loadAIRetryStatus();
    showToast(
      `AI allowance reset. ${result.resumedEntries} deferred entries can resume.`,
    );
  } catch (error) {
    showError(error.message);
  } finally {
    state.resettingAIAllowance = false;
    if (state.aiUsage) {
      renderAIUsage(state.aiUsage);
    }
  }
}

function releaseDate(release) {
  return release.published_at ?? release.created_at;
}

function renderReleaseControls() {
  const dictionary = state.summary?.dictionary;
  const current = state.releases.find((release) => release.status === "current");
  const canPublish = Boolean(dictionary?.dirty) && !state.releasing;
  elements.publish.disabled = !canPublish;
  elements.releaseNote.disabled = !canPublish;
  elements.publish.textContent = state.releasing
    ? "Publishing…"
    : current
      ? "Publish changes"
      : "Publish first release";

  if (!dictionary) {
    elements.releaseDescription.textContent = "Dictionary state is unavailable.";
  } else if (dictionary.dirty) {
    elements.releaseDescription.textContent =
      `Changes from ${dictionary.changedBy ?? "the import"} are ready. Publishing writes, reads back, and verifies an immutable R2 object before switching the live D1 pointer.`;
  } else if (current) {
    elements.releaseDescription.textContent =
      `Version ${current.version} is live. Its immutable R2 object was verified before activation.`;
  } else {
    elements.releaseDescription.textContent = "No unpublished changes are available.";
  }

  if (state.releases.length === 0) {
    const empty = document.createElement("p");
    empty.className = "release-empty";
    empty.textContent = "No releases have been published.";
    elements.releaseList.replaceChildren(empty);
    return;
  }

  elements.releaseList.replaceChildren(
    ...state.releases.map((release) => {
      const row = document.createElement("article");
      row.className = "release-row";

      const identity = document.createElement("div");
      identity.className = "release-identity";
      const version = document.createElement("strong");
      version.textContent = `v${release.version}`;
      const badge = document.createElement("span");
      badge.className = "status-badge";
      badge.dataset.status = release.status;
      badge.textContent = release.status;
      identity.append(version, badge);

      const metadata = document.createElement("div");
      metadata.className = "release-metadata";
      const entries = document.createElement("span");
      entries.textContent = `${release.entry_count} entries`;
      const date = document.createElement("span");
      date.textContent = formatDate(releaseDate(release));
      const checksum = document.createElement("code");
      checksum.title = release.checksum;
      checksum.textContent = release.checksum.slice(0, 12);
      metadata.append(entries, date, checksum);
      if (release.note) {
        const note = document.createElement("span");
        note.className = "release-note";
        note.textContent = release.note;
        metadata.append(note);
      }

      row.append(identity, metadata);

      if (release.status === "superseded" && current) {
        const actions = document.createElement("div");
        actions.className = "release-actions";
        const compare = document.createElement("button");
        compare.className = "quiet-button compact";
        compare.type = "button";
        compare.disabled = state.releasing;
        compare.textContent = "Compare";
        compare.addEventListener("click", () => {
          void compareReleases(release.version, current.version);
        });
        const rollback = document.createElement("button");
        rollback.className = "secondary-button compact";
        rollback.type = "button";
        rollback.disabled = state.releasing;
        rollback.textContent = "Roll back";
        rollback.addEventListener("click", () => {
          void rollbackRelease(release.version, current.version);
        });
        actions.append(compare, rollback);
        row.append(actions);
      }
      return row;
    }),
  );
}

function releaseEntryDescription(entry) {
  if (!entry) {
    return "—";
  }
  const aliases =
    entry.aliases.length > 0 ? ` · aliases: ${entry.aliases.join(", ")}` : "";
  return `${entry.translation} · ${entry.kind}${aliases}`;
}

function renderReleaseComparison() {
  const comparison = state.releaseComparison;
  if (!comparison) {
    elements.releaseComparison.hidden = true;
    elements.releaseComparisonList.replaceChildren();
    return;
  }

  elements.releaseComparison.hidden = false;
  elements.releaseComparisonTitle.textContent =
    `v${comparison.from.version} → v${comparison.to.version}`;
  elements.releaseComparisonSummary.textContent =
    `${comparison.summary.total} changes · ${comparison.summary.added} added · ` +
    `${comparison.summary.removed} removed · ${comparison.summary.changed} changed` +
    (comparison.truncated ? " · first 500 shown" : "");
  elements.releaseComparisonList.replaceChildren(
    ...comparison.changes.map((change) => {
      const item = document.createElement("article");
      item.className = "release-change";
      item.dataset.type = change.type;

      const heading = document.createElement("div");
      heading.className = "release-change-heading";
      const source = document.createElement("strong");
      source.textContent = change.source;
      const badge = document.createElement("span");
      badge.className = "status-badge";
      badge.textContent = change.type;
      heading.append(source, badge);

      const before = document.createElement("p");
      before.textContent = `Before: ${releaseEntryDescription(change.from)}`;
      const after = document.createElement("p");
      after.textContent = `After: ${releaseEntryDescription(change.to)}`;
      item.append(heading, before, after);
      return item;
    }),
  );
}

async function compareReleases(fromVersion, toVersion) {
  if (state.releasing) {
    return;
  }
  clearError();
  setReleasing(true, `Verifying v${fromVersion} and v${toVersion}…`);
  try {
    state.releaseComparison = await api(
      `/admin/api/releases/${fromVersion}/compare/${toVersion}`,
    );
    renderReleaseComparison();
    elements.releaseComparison.scrollIntoView({ behavior: "smooth", block: "nearest" });
  } catch (error) {
    showError(error.message);
  } finally {
    setReleasing(false);
  }
}

function listQuery(cursor = null) {
  const params = new URLSearchParams();
  if (elements.status.value) {
    params.set("status", elements.status.value);
  }
  if (elements.kind.value) {
    params.set("kind", elements.kind.value);
  }
  if (elements.search.value.trim()) {
    params.set("q", elements.search.value.trim());
  }
  if (cursor) {
    params.set("cursor", String(cursor));
  }
  params.set("limit", "50");
  params.set("_fresh", `${Date.now()}-${state.listLoadGeneration}`);
  return params.toString();
}

function translationDisplay(entry) {
  return entry.approved_translation ?? entry.machine_translation ?? "No translation";
}

function makeTranslationRow(entry) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "translation-row";
  button.dataset.id = String(entry.id);
  if (entry.id === state.selectedID) {
    button.classList.add("selected");
  }

  const top = document.createElement("div");
  top.className = "row-top";
  const source = document.createElement("span");
  source.className = "row-source";
  source.textContent = entry.source;
  const status = document.createElement("span");
  status.className = "status-pill";
  status.dataset.status = entry.status;
  status.textContent = entry.status;
  top.append(source, status);

  const translation = document.createElement("p");
  translation.className = "row-translation";
  translation.lang = "zh-Hans";
  translation.textContent = translationDisplay(entry);

  const meta = document.createElement("div");
  meta.className = "row-meta";
  const kind = document.createElement("span");
  kind.textContent = entry.kind;
  const seen = document.createElement("span");
  seen.textContent = `seen ${entry.seen_count}×`;
  meta.append(kind, seen);

  button.append(top, translation, meta);
  button.addEventListener("click", () => {
    void selectTranslation(entry.id);
  });
  return button;
}

function renderList() {
  elements.list.replaceChildren(
    ...state.translations.map((entry) => makeTranslationRow(entry)),
  );
  const count = state.translations.length;
  elements.queueStatus.textContent = state.loading
    ? "Loading queue…"
    : `${count} ${count === 1 ? "entry" : "entries"} loaded`;
  elements.loadMore.hidden = !state.nextCursor;
  elements.loadMore.disabled = state.loading;
}

async function loadList({
  append = false,
  preserveSelection = false,
  force = false,
} = {}) {
  if (state.loading && !force) {
    return;
  }
  const loadGeneration = ++state.listLoadGeneration;
  state.loading = true;
  clearError();
  renderList();
  try {
    const cursor = append ? state.nextCursor : null;
    const result = await api(`/admin/api/translations?${listQuery(cursor)}`);
    if (loadGeneration !== state.listLoadGeneration) {
      return;
    }
    state.translations = append
      ? [...state.translations, ...result.translations]
      : result.translations;
    state.nextCursor = result.nextCursor;

    if (!append && !preserveSelection && Number.isSafeInteger(state.reviewedID)) {
      state.selectedID = selectionAfterReviewedEntry(
        state.translations,
        state.reviewedID,
      );
      state.reviewedID = null;
      state.detail = null;
    } else if (
      !preserveSelection ||
      !state.translations.some((entry) => entry.id === state.selectedID)
    ) {
      state.selectedID = state.translations[0]?.id ?? null;
      state.detail = null;
    }
  } catch (error) {
    if (loadGeneration === state.listLoadGeneration) {
      showError(error.message);
    }
  } finally {
    if (loadGeneration === state.listLoadGeneration) {
      state.loading = false;
      renderList();
    }
  }

  if (
    loadGeneration === state.listLoadGeneration &&
    state.selectedID &&
    !state.detail
  ) {
    await selectTranslation(state.selectedID);
  } else if (
    loadGeneration === state.listLoadGeneration &&
    !state.selectedID
  ) {
    renderEmptyDetail();
  }
}

function metadataItem(label, value) {
  const term = document.createElement("dt");
  term.textContent = label;
  const description = document.createElement("dd");
  description.textContent = value ?? "—";
  return [term, description];
}

function renderAliases(aliases) {
  if (aliases.length === 0) {
    const empty = document.createElement("span");
    empty.className = "summary-note";
    empty.textContent = "No aliases";
    elements.aliases.replaceChildren(empty);
    return;
  }
  elements.aliases.replaceChildren(
    ...aliases.map((item) => {
      const chip = document.createElement("span");
      chip.className = "alias-chip";
      chip.textContent = item.alias;
      return chip;
    }),
  );
}

function renderRevisions(revisions) {
  elements.revisionCount.textContent = String(revisions.length);
  if (revisions.length === 0) {
    const item = document.createElement("li");
    item.className = "summary-note";
    item.textContent = "No human review decisions yet.";
    elements.revisions.replaceChildren(item);
    return;
  }

  elements.revisions.replaceChildren(
    ...revisions.map((revision) => {
      const item = document.createElement("li");
      item.className = "revision-item";
      const title = document.createElement("p");
      title.className = "revision-title";
      title.textContent = `${revision.previous_status ?? "new"} → ${revision.new_status}`;
      const before = document.createElement("p");
      before.className = "revision-copy";
      before.lang = "zh-Hans";
      before.textContent = `Before: ${revision.previous_translation ?? "No translation"}`;
      const after = document.createElement("p");
      after.className = "revision-copy";
      after.lang = "zh-Hans";
      after.textContent = `After: ${
        revision.new_translation ??
        (revision.new_status === "rejected" ? "Translation rejected" : "No translation")
      }`;
      const meta = document.createElement("p");
      meta.className = "revision-meta";
      meta.textContent = `${revision.actor} · ${formatDate(revision.created_at)}`;
      item.append(title, before, after, meta);

      const currentTranslation = state.detail?.translation.approved_translation;
      if (
        revision.previous_translation &&
        revision.previous_translation !== currentTranslation
      ) {
        const restore = document.createElement("button");
        restore.className = "quiet-button compact revision-restore";
        restore.type = "button";
        restore.disabled = state.saving;
        restore.textContent = "Restore previous";
        restore.addEventListener("click", () => {
          void restoreRevision(revision.id);
        });
        item.append(restore);
      }
      return item;
    }),
  );
}

function renderSimilar(similar) {
  if (similar.length === 0) {
    const empty = document.createElement("p");
    empty.className = "summary-note";
    empty.textContent = "No approved reference entries are available yet.";
    elements.similar.replaceChildren(empty);
    return;
  }

  elements.similar.replaceChildren(
    ...similar.map((entry) => {
      const card = document.createElement("article");
      card.className = "similar-entry";
      const heading = document.createElement("div");
      heading.className = "similar-entry-heading";
      const source = document.createElement("p");
      source.className = "similar-entry-source";
      source.textContent = entry.source;
      const type = document.createElement("span");
      type.className = "similar-entry-type";
      type.textContent =
        entry.reference_type === "text"
          ? `${entry.kind} · text match`
          : `${entry.kind} · same kind`;
      heading.append(source, type);
      const translation = document.createElement("p");
      translation.className = "similar-entry-translation";
      translation.lang = "zh-Hans";
      translation.textContent = entry.approved_translation;
      card.append(heading, translation);
      return card;
    }),
  );
}

function setBadge(element, value, status = null) {
  element.textContent = value;
  if (status) {
    element.dataset.status = status;
  } else {
    delete element.dataset.status;
  }
}

function renderEmptyDetail() {
  elements.emptyDetail.hidden = false;
  elements.detailContent.hidden = true;
}

function updateReviewAction() {
  const action = state.detail
    ? reviewActionForInput(
        state.detail.translation,
        elements.translationInput.value,
      )
    : null;
  elements.approve.disabled = state.saving || action === null;
  elements.approve.textContent =
    action === "edit" ? "Save edited translation" : "Approve translation";
}

function renderDetail() {
  if (!state.detail) {
    renderEmptyDetail();
    return;
  }
  const { translation, aliases, revisions, similar = [] } = state.detail;
  elements.emptyDetail.hidden = true;
  elements.detailContent.hidden = false;

  setBadge(elements.detailStatus, translation.status, translation.status);
  setBadge(elements.detailKind, translation.kind);
  setBadge(elements.detailOrigin, translation.origin);
  setText(elements.detailSource, translation.source);
  setText(elements.detailNormalized, translation.normalized_source);
  setText(elements.detailMachine, translation.machine_translation, "No machine suggestion");
  setText(elements.detailApproved, translation.approved_translation, "Not approved yet");
  setText(elements.reviewSource, translation.source);

  const editable = translation.approved_translation ?? translation.machine_translation ?? "";
  elements.translationInput.value = editable;
  elements.translationLength.textContent = String(editable.length);
  updateReviewAction();

  elements.metadata.replaceChildren(
    ...[
      ...metadataItem("Locale", translation.locale),
      ...metadataItem("First seen", formatDate(translation.first_seen_at)),
      ...metadataItem("Last seen", formatDate(translation.last_seen_at)),
      ...metadataItem("Seen count", String(translation.seen_count)),
      ...metadataItem("Approved by", translation.approved_by ?? "—"),
      ...metadataItem("Approved at", formatDate(translation.approved_at)),
      ...metadataItem("Deferred until", formatDate(translation.deferred_until)),
    ],
  );
  renderAliases(aliases);
  renderSimilar(similar);
  renderRevisions(revisions);
}

async function selectTranslation(id) {
  state.selectedID = id;
  renderList();
  clearError();
  elements.saveState.textContent = "Loading…";
  try {
    const detail = await api(
      `/admin/api/translations/${id}?_fresh=${Date.now()}`,
    );
    const reconciled = reconcileQueueEntry(
      state.translations,
      detail.translation,
      elements.status.value,
      elements.kind.value,
    );
    state.translations = reconciled.entries;

    if (!reconciled.matches) {
      state.selectedID = reconciled.nextID;
      state.detail = null;
      renderList();
      renderDetail();
      if (reconciled.nextID !== null) {
        await selectTranslation(reconciled.nextID);
      }
      return;
    }

    state.detail = detail;
    state.selectedID = detail.translation.id;
    renderList();
    renderDetail();
  } catch (error) {
    showError(error.message);
  } finally {
    elements.saveState.textContent = "";
  }
}

function setSaving(saving) {
  state.saving = saving;
  updateReviewAction();
  elements.reject.disabled = saving;
  elements.defer.disabled = saving;
  elements.saveState.textContent = saving ? "Saving decision…" : "";
}

function loadNextReview(currentID) {
  elements.saveState.textContent = "Saved. Loading next entry…";
  window.location.replace(reviewReloadURL(currentID, ADMIN_UI_BUILD));
}

async function review(action, extra = {}) {
  if (!state.detail || state.saving) {
    return;
  }
  clearError();
  setSaving(true);
  const currentID = state.detail.translation.id;
  let navigating = false;
  try {
    await api(`/admin/api/translations/${currentID}/review`, {
      method: "POST",
      body: JSON.stringify({
        action,
        expectedUpdatedAt: state.detail.translation.updated_at,
        ...extra,
      }),
    });
    navigating = true;
    loadNextReview(currentID);
    return;
  } catch (error) {
    showError(error.message);
    if (error.status === 409) {
      await selectTranslation(currentID);
    }
  } finally {
    if (!navigating) {
      setSaving(false);
    }
  }
}

async function restoreRevision(revisionID) {
  if (!state.detail || state.saving) {
    return;
  }
  const revision = state.detail.revisions.find((item) => item.id === revisionID);
  if (
    !revision?.previous_translation ||
    !window.confirm(
      `Restore this earlier translation?\n\n${revision.previous_translation}\n\n` +
      "The restoration will be recorded as a new edit and will not change the live dictionary until published.",
    )
  ) {
    return;
  }

  clearError();
  setSaving(true);
  const currentID = state.detail.translation.id;
  let navigating = false;
  try {
    await api(
      `/admin/api/translations/${currentID}/revisions/${revisionID}/restore`,
      {
        method: "POST",
        body: JSON.stringify({
          expectedUpdatedAt: state.detail.translation.updated_at,
        }),
      },
    );
    navigating = true;
    loadNextReview(currentID);
    return;
  } catch (error) {
    showError(error.message);
    if (error.status === 409) {
      await selectTranslation(currentID);
    }
  } finally {
    if (!navigating) {
      setSaving(false);
    }
  }
}

async function loadSummary() {
  const summary = await api("/admin/api/summary");
  renderSummary(summary);
}

async function loadReleases() {
  const result = await api("/admin/api/releases");
  state.releases = result.releases;
  renderReleaseControls();
}

function setReleasing(releasing, message = "") {
  state.releasing = releasing;
  elements.releaseActionState.textContent = message;
  renderReleaseControls();
}

async function publishDictionary() {
  if (state.releasing || !state.summary?.dictionary?.dirty) {
    return;
  }
  const expectedChangedAt = state.summary.dictionary.changedAt;
  if (
    !window.confirm(
      "Publish all approved and edited translations? The Worker will verify the immutable R2 object before making it live.",
    )
  ) {
    return;
  }

  clearError();
  setReleasing(true, "Writing and verifying R2 release…");
  try {
    const result = await api("/admin/api/releases/publish", {
      method: "POST",
      body: JSON.stringify({
        expectedChangedAt,
        note: elements.releaseNote.value.trim() || null,
      }),
    });
    elements.releaseNote.value = "";
    await Promise.all([loadSummary(), loadReleases()]);
    showToast(`Dictionary v${result.release.version} is now live.`);
  } catch (error) {
    showError(error.message);
    await Promise.allSettled([loadSummary(), loadReleases()]);
  } finally {
    setReleasing(false);
  }
}

async function rollbackRelease(targetVersion, expectedCurrentVersion) {
  if (state.releasing) {
    return;
  }
  if (
    !window.confirm(
      `Roll back the live dictionary from v${expectedCurrentVersion} to verified v${targetVersion}?`,
    )
  ) {
    return;
  }

  clearError();
  setReleasing(true, `Verifying and restoring v${targetVersion}…`);
  try {
    await api(`/admin/api/releases/${targetVersion}/rollback`, {
      method: "POST",
      body: JSON.stringify({ expectedCurrentVersion }),
    });
    await Promise.all([loadSummary(), loadReleases()]);
    showToast(`Dictionary rolled back to v${targetVersion}.`);
  } catch (error) {
    showError(error.message);
    await Promise.allSettled([loadSummary(), loadReleases()]);
  } finally {
    setReleasing(false);
  }
}

async function refreshAll() {
  clearError();
  elements.refresh.disabled = true;
  elements.refresh.textContent = "Refreshing…";
  state.detail = null;
  try {
    await Promise.all([
      loadSummary(),
      loadReleases(),
      loadAIRetryStatus(),
      loadAIUsage(),
      loadList({ preserveSelection: true }),
    ]);
  } catch (error) {
    showError(error.message);
  } finally {
    elements.refresh.disabled = false;
    elements.refresh.textContent = "↻ Full refresh";
  }
}

elements.filterForm.addEventListener("submit", (event) => {
  event.preventDefault();
  void loadList();
});

elements.status.addEventListener("change", () => {
  void loadList();
});

elements.kind.addEventListener("change", () => {
  void loadList();
});

elements.search.addEventListener("input", () => {
  clearTimeout(state.searchTimer);
  state.searchTimer = setTimeout(() => {
    void loadList();
  }, 280);
});

elements.translationInput.addEventListener("input", () => {
  const length = elements.translationInput.value.length;
  elements.translationLength.textContent = String(length);
  updateReviewAction();
});

elements.refresh.addEventListener("click", () => {
  window.location.reload();
});

elements.retryFailed.addEventListener("click", () => {
  void retryFailedTranslations();
});

elements.resetAIAllowance.addEventListener("click", () => {
  void resetAIAllowance();
});

elements.publish.addEventListener("click", () => {
  void publishDictionary();
});

elements.closeComparison.addEventListener("click", () => {
  state.releaseComparison = null;
  renderReleaseComparison();
});

elements.loadMore.addEventListener("click", () => {
  void loadList({ append: true, preserveSelection: true });
});

elements.copySource.addEventListener("click", async () => {
  if (!state.detail) {
    return;
  }
  await navigator.clipboard.writeText(state.detail.translation.source);
  showToast("Source copied.");
});

elements.approve.addEventListener("click", () => {
  if (!state.detail) {
    return;
  }
  const translation = normalizeReviewTranslation(elements.translationInput.value);
  const action = reviewActionForInput(state.detail.translation, translation);
  if (action === "approve") {
    void review("approve");
  } else if (action === "edit") {
    void review("edit", { translation });
  }
});

elements.reject.addEventListener("click", () => {
  if (window.confirm("Reject this translation suggestion?")) {
    void review("reject");
  }
});

elements.defer.addEventListener("click", () => {
  const deferUntil = new Date();
  deferUntil.setUTCDate(
    deferUntil.getUTCDate() + Number.parseInt(elements.deferDuration.value, 10),
  );
  void review("defer", { deferUntil: deferUntil.toISOString() });
});

async function initialize() {
  try {
    const [session] = await Promise.all([
      api("/admin/api/session"),
      loadSummary(),
      loadReleases(),
      loadAIRetryStatus(),
      loadAIUsage(),
      loadList(),
    ]);
    elements.sessionEmail.textContent = `${session.email} · UI ${ADMIN_UI_BUILD}`;
  } catch (error) {
    showError(error.message);
    elements.sessionEmail.textContent = "Access session unavailable";
  }
}

void initialize();
