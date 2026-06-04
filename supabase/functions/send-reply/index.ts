// ╔══════════════════════════════════════════════════════════════════════╗
// ║  Edge Function : send-reply                                           ║
// ║  Envoi d'emails OniProMail / ONIASSIST via Resend                    ║
// ║                                                                      ║
// ║  Deux modes :                                                        ║
// ║   1. compose  → nouveau message OniProMail                           ║
// ║      { compose:true, from_alias, to, cc, bcc, subject, body }        ║
// ║   2. reply    → réponse ONIASSIST à un email reçu                    ║
// ║      { email_id, manager_answer, custom_reply }                      ║
// ║                                                                      ║
// ║  Secrets requis (Supabase → Edge Functions → Secrets) :              ║
// ║   - RESEND_API_KEY            (obligatoire, envoi)                    ║
// ║   - SUPABASE_URL             (auto)                                   ║
// ║   - SUPABASE_SERVICE_ROLE_KEY (mode reply : lecture table emails)    ║
// ║                                                                      ║
// ║  Déploiement :  supabase functions deploy send-reply                 ║
// ╚══════════════════════════════════════════════════════════════════════╝

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// "a@x.fr, b@y.fr ; c@z.fr" → ["a@x.fr","b@y.fr","c@z.fr"]
function toList(v: unknown): string[] | undefined {
  if (!v) return undefined;
  if (Array.isArray(v)) return v.map(String).map((s) => s.trim()).filter(Boolean);
  const arr = String(v).split(/[,;]+/).map((s) => s.trim()).filter(Boolean);
  return arr.length ? arr : undefined;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Texte brut → HTML lisible (retours à la ligne préservés)
function bodyToHtml(text: string): string {
  const safe = escapeHtml(text || "").replace(/\n/g, "<br/>");
  return `<!doctype html><html><body style="margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:14px;line-height:1.65;color:#16120D;">${safe}</body></html>`;
}

// Appel API Resend (POST /emails)
async function resendSend(payload: Record<string, unknown>): Promise<{ id?: string }> {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    // Resend renvoie { message, name } — on remonte un message clair (ex. domaine non vérifié)
    const msg = (data && (data.message || data.error)) || `Resend HTTP ${res.status}`;
    throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
  }
  return data;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);

  if (!RESEND_API_KEY) {
    return json({
      ok: false,
      error: "Secret RESEND_API_KEY manquant. Supabase → Settings → Edge Functions → Secrets → ajoute RESEND_API_KEY.",
    }, 500);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: "Corps JSON invalide" }, 400);
  }

  try {
    // ───────────── MODE 1 : compose (OniProMail) ─────────────
    if (payload.compose) {
      const from = String(payload.from_alias || "").trim();
      if (!from) return json({ ok: false, error: "Expéditeur (from_alias) manquant" }, 400);

      const to = toList(payload.to);
      if (!to) return json({ ok: false, error: "Destinataire manquant" }, 400);

      const body = String(payload.body || "");
      const result = await resendSend({
        from,
        to,
        cc: toList(payload.cc),
        bcc: toList(payload.bcc),
        subject: String(payload.subject || "(sans objet)"),
        text: body,
        html: bodyToHtml(body),
        reply_to: from,
      });
      return json({ ok: true, id: result.id });
    }

    // ───────────── MODE 2 : reply (ONIASSIST) ─────────────
    if (payload.email_id) {
      if (!SUPABASE_URL || !SERVICE_ROLE) {
        return json({ ok: false, error: "Config Supabase (URL / service role) manquante pour le mode réponse" }, 500);
      }
      const sb = createClient(SUPABASE_URL, SERVICE_ROLE);
      const { data: email, error } = await sb
        .from("emails")
        .select("from_address,to_address,subject")
        .eq("id", payload.email_id)
        .maybeSingle();

      if (error) return json({ ok: false, error: "Lecture email : " + error.message }, 500);
      if (!email) return json({ ok: false, error: "Email introuvable (id=" + payload.email_id + ")" }, 404);

      const replyBody = (String(payload.custom_reply || "").trim()) || (String(payload.manager_answer || "").trim());
      if (!replyBody) return json({ ok: false, error: "Réponse vide" }, 400);

      const from = email.to_address;            // l'alias qui a reçu = expéditeur de la réponse
      const to = email.from_address;            // on répond à l'expéditeur d'origine
      if (!from || !to) return json({ ok: false, error: "Adresses de l'email d'origine incomplètes" }, 400);

      const subj = /^re\s*:/i.test(email.subject || "") ? email.subject : "Re: " + (email.subject || "");
      const result = await resendSend({
        from,
        to,
        subject: subj,
        text: replyBody,
        html: bodyToHtml(replyBody),
        reply_to: from,
      });
      return json({ ok: true, id: result.id, reply: replyBody });
    }

    return json({ ok: false, error: "Payload non reconnu (attendu : compose=true OU email_id)" }, 400);
  } catch (e) {
    // Erreur Resend (ex. « The domain is not verified ») remontée telle quelle au client
    return json({ ok: false, error: String((e as Error)?.message || e) }, 502);
  }
});
