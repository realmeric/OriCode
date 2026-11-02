// The gate on a character's memory. Whatever goes to the small model and whatever reaches a memory
// file passes through here first, and a line that looks like it holds a secret is dropped whole:
// the memory loses a line it could have kept rather than keep a key. Tool output never comes this
// far, so what a command read out of OriPass or `bw` isn't seen at all; this catches a secret
// someone typed or an agent repeated.

const shapes: RegExp[] = [
  /-----BEGIN [A-Z0-9 ]*-----/,
  /\bssh-(?:rsa|dss|ed25519) AAAA/,
  /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
  /\bgh[pousr]_[A-Za-z0-9]{20,}/,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/,
  /\bglpat-[A-Za-z0-9_-]{16,}/,
  /\bsk-[A-Za-z0-9_-]{16,}/,
  /\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/,
  /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
  /\bAIza[0-9A-Za-z_-]{30,}/,
  /\bnpm_[A-Za-z0-9]{30,}/,
  /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}/,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
  /\bBW_(?:SESSION|PASSWORD|CLIENTSECRET)\b/,
  /\botpauth:\/\//i,
  /\bbearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /\b[a-z][a-z0-9+.-]*:\/\/[^/\s:@]+:[^/\s@]+@/i,
];

const words = "pass(?:word|wd|phrase|code)?|pwd|parola(?:m|n|s[ıi])?|şifre(?:m|n|si)?|sifre(?:m|n|si)?|secret|token|api[_ -]?key|access[_ -]?key|private[_ -]?key|client[_ -]?secret|credential|anahtar(?:ım|ı)?";

/// `password: x`, `API_KEY=x`, `şifrem şu: x`, and `password hunter2`, where what follows the word
/// has a digit or a sign in it and so isn't the sentence going on.
const told = [new RegExp(`(?<![\\p{L}\\p{N}])(?:${words})["']?\\s*(?:is\\s|=>?|:|şu:?)\\s*\\S+`, "iu"), new RegExp(`(?<![\\p{L}\\p{N}])(?:${words})\\s+(?=\\S*[\\d!@#$%^&*_+=])\\S{6,}`, "iu")];

/// A long run of letters and digits that doesn't read as a word, a path or an id anyone would keep.
function looksRandom(token: string): boolean {
  if (token.length < 32 || !/\d/.test(token) || !/[A-Za-z]/.test(token)) return false;
  const counts = new Map<string, number>();
  for (const letter of token) counts.set(letter, (counts.get(letter) ?? 0) + 1);
  let entropy = 0;
  for (const count of counts.values()) entropy -= (count / token.length) * Math.log2(count / token.length);
  return entropy > 3.2;
}

/// A card number: 13 to 19 digits that pass the Luhn check.
function looksLikeCard(line: string): boolean {
  for (const found of line.matchAll(/\b\d(?:[ -]?\d){12,18}\b/g)) {
    const digits = found[0].replace(/\D/g, "");
    let sum = 0;
    for (let index = 0; index < digits.length; index++) {
      const digit = Number(digits[digits.length - 1 - index]);
      sum += index % 2 ? (digit > 4 ? digit * 2 - 9 : digit * 2) : digit;
    }
    if (sum % 10 === 0) return true;
  }
  return false;
}

export function holdsSecret(line: string): boolean {
  return shapes.some((shape) => shape.test(line)) || told.some((shape) => shape.test(line)) || looksLikeCard(line) || (line.match(/[A-Za-z0-9+/_=-]{32,}/g) ?? []).some(looksRandom);
}

/// The text without any line that holds a secret, and how many went.
export function withoutSecrets(text: string): { kept: string; dropped: number } {
  const lines = text.split("\n");
  const kept = lines.filter((line) => !holdsSecret(line));
  return { kept: kept.join("\n"), dropped: lines.length - kept.length };
}
