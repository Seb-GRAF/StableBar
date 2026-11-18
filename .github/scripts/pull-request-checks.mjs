// The logic of the Linked issue and Description checks. .github/workflows/pull-request-checks.yml
// runs the default branch's copy of this module, so a pull request never runs its own.

const keywords = "close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved";
const sectionNames = ["Problem", "Changes", "Testing"];
const attributionHint = 'End it with the model and harness that did the work, such as "Claude Opus 5.5 via Claude Code", or with "No agent".';

// The text GitHub shows, following CommonMark: auto-generated blocks and comments are hidden,
// code is shown as written, a comment that starts a line hides everything up to its "-->" (or the
// rest of the description when it never closes), and an unclosed "<!--" inside a line is text.
export function visibleText(body) {
  const text = (body ?? "")
    .replace(/\r\n/g, "\n")
    .replace(/<!-- This is an auto-generated (?:comment|description)[\s\S]*?<!-- end of auto-generated (?:comment|description)[\s\S]*?-->/gi, "");
  const shown = [];
  let paragraph = [];
  let fence = null;
  let comment = null;
  const flush = () => {
    if (paragraph.length > 0) shown.push(inlineText(paragraph.join("\n")));
    paragraph = [];
  };
  for (const line of text.split("\n")) {
    if (fence) {
      shown.push(line);
      if (fence.test(line)) fence = null;
    } else if (comment !== null) {
      const end = line.indexOf("-->");
      if (end !== -1) {
        shown.push(comment + inlineText(line.slice(end + 3)));
        comment = null;
      }
    } else if (/^ {0,3}(`{3,}|~{3,})/.test(line)) {
      flush();
      shown.push(line);
      const [, marks] = line.match(/^ {0,3}(`{3,}|~{3,})/);
      fence = new RegExp(`^ {0,3}${marks[0]}{${marks.length},}\\s*$`);
    } else if (/^ {0,3}<!--/.test(line)) {
      flush();
      const start = line.indexOf("<!--");
      const end = line.indexOf("-->", start + 4);
      if (end === -1) comment = line.slice(0, start);
      else shown.push(line.slice(0, start) + inlineText(line.slice(end + 3)));
    } else if (/^\s*$/.test(line) || /^ {0,3}#{1,6}(\s|$)/.test(line)) {
      flush();
      shown.push(inlineText(line));
    } else {
      paragraph.push(line);
    }
  }
  flush();
  if (comment !== null) shown.push(comment);
  return shown.join("\n");
}

// Inside a paragraph, whichever starts first wins: a code span keeps its text, a closed comment
// is hidden, and an unclosed "<!--" or an unmatched backtick is text.
function inlineText(text) {
  let shown = "";
  let index = 0;
  while (index < text.length) {
    const next = text.slice(index).search(/`|<!--/);
    if (next === -1) return shown + text.slice(index);
    shown += text.slice(index, index + next);
    index += next;
    if (text.startsWith("<!--", index)) {
      const end = text.indexOf("-->", index + 4);
      if (end === -1) return shown + text.slice(index);
      index = end + 3;
    } else {
      const run = text.slice(index).match(/^`+/)[0];
      const closing = new RegExp(`(?<!\`)\`{${run.length}}(?!\`)`, "g");
      closing.lastIndex = index + run.length;
      const close = closing.exec(text);
      const end = close ? close.index + run.length : index + run.length;
      shown += text.slice(index, end);
      index = end;
    }
  }
  return shown;
}

export function needsIssue(title) {
  return /^(fix|feat|perf)(\([^)]*\))?!?:/i.test(title ?? "");
}

export function closingIssueNumbers(body, repository) {
  const [owner, name] = repository.toLowerCase().split("/");
  const isThisRepository = (refOwner, refName) => refOwner.toLowerCase() === owner && refName.toLowerCase() === name;
  const reference = new RegExp(
    `\\b(?:${keywords})\\b:?\\s+(?:([\\w.-]+)/([\\w.-]+)#(\\d+)|#(\\d+)|https://github\\.com/([\\w.-]+)/([\\w.-]+)/issues/(\\d+))`,
    "gi");
  const numbers = [];
  for (const [, refOwner, refName, refNumber, localNumber, urlOwner, urlName, urlNumber] of visibleText(body).matchAll(reference)) {
    const number = localNumber ? Number(localNumber)
      : refNumber && isThisRepository(refOwner, refName) ? Number(refNumber)
      : urlNumber && isThisRepository(urlOwner, urlName) ? Number(urlNumber)
      : undefined;
    if (number > 0 && !numbers.includes(number)) numbers.push(number);
  }
  return numbers;
}

// closingIssues are GitHub's links ({ number, repository: "owner/name" }), which only cover pull
// requests to the default branch. A stacked pull request names its issue in the description.
export function checkLinkedIssue({ title, body, repository, baseRef, defaultBranch, closingIssues }) {
  if (!needsIssue(title)) return { ok: true, message: "No issue needed for this type." };
  if (closingIssues.some((issue) => issue.repository.toLowerCase() === repository.toLowerCase()))
    return { ok: true, message: "Closes an issue." };
  if (baseRef !== defaultBranch && closingIssueNumbers(body, repository).length > 0)
    return { ok: true, message: "Closes an issue named in the description." };
  return {
    ok: false,
    message: 'A fix, feat or perf pull request has to close an issue: add "Fixes #N" to the description, after opening the issue if there is none.',
  };
}

// Visible lines under each level-2 heading, keyed by its lowercased name. A level-1 or level-2
// heading ends a section; a repeated heading keeps the first section.
function sections(text) {
  const found = new Map();
  let current = null;
  for (const line of text.split("\n")) {
    if (/^#{1,2}\s/.test(line)) {
      const name = line.match(/^##\s+(.*?)\s*$/)?.[1].toLowerCase();
      current = name !== undefined && !found.has(name) ? name : null;
      if (current !== null) found.set(current, []);
    } else if (current !== null) {
      found.get(current).push(line);
    }
  }
  return found;
}

function joined(items) {
  return items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;
}

export function checkDescription(body) {
  const text = visibleText(body);
  const found = sections(text);
  const missing = sectionNames.filter((name) => !(found.get(name.toLowerCase()) ?? []).some((line) => /\S/.test(line)));
  const lastLine = text.split("\n").filter((line) => /\S/.test(line)).at(-1)?.trim() ?? "";
  if (!/^no agent\.?$/i.test(lastLine) && !/\svia\s/i.test(lastLine)) missing.push("attribution line");
  if (missing.length === 0) return { ok: true, missing, message: "Description filled in." };
  const missingSections = missing.filter((part) => sectionNames.includes(part));
  const message = [
    missingSections.length > 0 ? `Fill in ${joined(missingSections)} in the description.` : null,
    missing.includes("attribution line") ? attributionHint : null,
  ].filter(Boolean).join(" ");
  return { ok: false, missing, message };
}
