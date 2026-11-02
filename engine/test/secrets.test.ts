// What the gate on a character's memory holds back and lets through. Each secret is put together
// here so that nothing in the repository looks like one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { holdsSecret, withoutSecrets } from "../secrets.ts";

const hex = "9f8e7d6c5b4a3210".repeat(3);
const mixed = "aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5";

const secrets: Record<string, string> = {
  "a PEM key": `-----BEGIN OPENSSH ${"PRIVATE"} KEY-----`,
  "an RSA key": `-----BEGIN RSA ${"PRIVATE"} KEY-----`,
  "a public key line": `ssh-${"ed25519"} AAAAC3NzaC1lZDI1NTE5AAAAIJ`,
  "an AWS key id": `key is ${"AKIA"}IOSFODNN7EXAMPLE`,
  "a GitHub token": `${"ghp"}_${mixed}`,
  "a fine-grained GitHub token": `${"github"}_pat_11ABCDEFG0abcdefghijkl`,
  "a GitLab token": `${"glpat"}-abcdefghij0123456789`,
  "an Anthropic key": `use ${"sk"}-ant-api03-abcdefghijklmnop`,
  "an OpenAI key": `${"sk"}-proj-abcdefghijklmnopqrstuv`,
  "a Stripe key": `${"sk"}_live_abcdefghijklmnop0123`,
  "a Slack token": `${"xoxb"}-1234567890-abcdefghij`,
  "a Google key": `${"AIza"}SyD-abcdefghijklmnopqrstuvwxyz012345`,
  "an npm token": `${"npm"}_abcdefghijklmnopqrstuvwxyz0123456789`,
  "a JWT": `${"eyJ"}hbGciOiJIUzI1NiJ9.${"eyJ"}zdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N`,
  "a Bitwarden session": `export ${"BW"}_SESSION=abc`,
  "a TOTP secret": `${"otpauth"}://totp/GitHub?secret=JBSWY3DPEHPK3PXP`,
  "a bearer header": `Authorization: ${"Bearer"} abcdefghijklmnop.qrstuv`,
  "credentials in a URL": `postgres://meric:${"hunter2"}@db.example.com/app`,
  "a password said": `the ${"password"}: correct-horse`,
  "a password assigned": `DB_${"PASSWORD"}=correct-horse`,
  "a password said in passing": `my ${"password"} hunter2!`,
  "a Turkish password": `${"şifrem"} şu: kedi1234`,
  "a Turkish password in passing": `${"parola"} kedi1234`,
  "an API key said": `${"API_KEY"} = abc`,
  "a token said": `${"token"} is abc`,
  "a card number": "kartım 4539 1488 0343 6467",
  "a long random run": `value ${mixed}`,
  "a long hex digest": hex,
};

for (const [name, line] of Object.entries(secrets)) {
  test(`held back: ${name}`, () => {
    assert.ok(holdsSecret(line), line);
    assert.equal(withoutSecrets(`before\n${line}\nafter`).kept, "before\nafter");
  });
}

const ordinary = [
  "Developer, writes in Turkish, signs commits himself with an OriPass key.",
  "OriPass, ~/Documents/Projects/apps/OriPass: his password manager; it holds the SSH agent behind every push.",
  "A signature or ssh that hangs is a person being asked.",
  "The Mac has 16 GB: six simulators took it to a load of 900 and made signing hang.",
  "Blackjack Club 0.0.9 went live on 2026-11-02, commit 753412c.",
  "~/Library/Developer/OriCode.noindex/DerivedData/Build/Products/Debug",
  "Şifre yöneticisi OriPass, Bitwarden'ın kendi CLI'ını kullanır.",
  "He wants the model's token count in the footer.",
];

for (const line of ordinary) {
  test(`kept: ${line.slice(0, 40)}`, () => assert.equal(holdsSecret(line), false, line));
}
