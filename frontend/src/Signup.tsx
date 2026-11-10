import { useState } from "react"
import { signup } from "./api"
import "./Login.css"

// The platform's own host, weaver.<domain>: make a tenant. Its app is at
// <name>.<domain>, which this hands the new token to (see `api.ts`).
const domain = location.hostname.replace(/^weaver\./, "")

export function Signup() {
  const [name, setName] = useState("")
  const [password, setPassword] = useState("")
  const [invite, setInvite] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const { url, token } = await signup(name.trim().toLowerCase(), password, invite.trim())
      location.href = `${url}#token=${encodeURIComponent(token)}`
    } catch (err) {
      setError(err instanceof Error ? err.message : "Sign-up failed")
      setBusy(false)
    }
  }

  return (
    <div className="login">
      <form className="login-box" onSubmit={submit}>
        <div className="login-title">weaver</div>
        <input
          className="login-input"
          placeholder="name"
          value={name}
          autoFocus
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          onChange={(e) => setName(e.target.value)}
        />
        <div className="login-note">
          {name.trim() ? `${name.trim().toLowerCase()}.${domain}` : `your address: <name>.${domain}`}
        </div>
        <input
          type="password"
          className="login-input"
          placeholder="password (8+ characters)"
          autoComplete="new-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <input
          className="login-input"
          placeholder="invite code"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          value={invite}
          onChange={(e) => setInvite(e.target.value)}
        />
        {error && <div className="login-error">{error}</div>}
        <button
          className="login-btn"
          type="submit"
          disabled={busy || !name.trim() || password.length < 8 || !invite.trim()}
        >
          {busy ? "…" : "Sign up"}
        </button>
      </form>
    </div>
  )
}
