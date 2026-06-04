// ╔══════════════════════════════════════════════════════════════════════╗
// ║  Edge Function : domain-setup                                        ║
// ║  Accompagnement « passe chez nous » — vérification du domaine client ║
// ║                                                                      ║
// ║  Pilote l'API Resend pour qu'un client utilise SON domaine           ║
// ║  (ex. contact@sa-boite.fr) en envoi depuis OniProMail.               ║
// ║                                                                      ║
// ║  Actions (champ "action") :                                          ║
// ║   - "setup"  : crée le domaine dans Resend s'il n'existe pas,        ║
// ║                renvoie la liste des enregistrements DNS à coller     ║
// ║                (SPF, DKIM, DMARC) + le statut.                       ║
// ║   - "verify" : demande à Resend de revérifier le DNS.               ║
// ║   - "status" : renvoie l'état courant + les enregistrements.        ║
// ║                                                                      ║
// ║  Entrée :  { domain:"sa-boite.fr", action:"setup"|"verify"|"status" }║
// ║  Sortie :  { ok, domain, id, status, records:[...], hint }          ║
// ║                                                                      ║
// ║  Secret requis :  RESEND_API_KEY                                     ║
// ║  Déploiement   :  supabase functions deploy domain-setup            ║
// ╚══════════════════════════════════════════════════════════════════════╝

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND = "https://api.resend.com";

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

async function resend(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(RESEND + path, {
    ...init,
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

// Normalise les enregistrements Resend en format affichable par le wizard
// Resend renvoie : { record, name, type, ttl, status, value, priority }
function normalizeRecords(records: unknown[]): unknown[] {
  return (records || []).map((r) => {
    const rec = r as Record<string, unknown>;
    return {
      purpose: rec.record ?? "",              // "SPF" | "DKIM" | ...
      type: rec.type ?? "TXT",                // TXT | MX | CNAME
      name: rec.name ?? "@",                  // sous-domaine / hôte
      value: rec.value ?? "",                 // valeur à coller
      priority: rec.priority ?? null,         // pour les MX
      ttl: rec.ttl ?? "Auto",
      status: rec.status ?? "not_started",    // verified | pending | ...
    };
  });
}

// Validation simple d'un nom de domaine
function isValidDomain(d: string): boolean {
  return /^(?!-)[a-z0-9-]{1,63}(?<!-)(\.[a-z0-9-]{1,63})+$/i.test(d);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);

  if (!RESEND_API_KEY) {
    return json({
      ok: false,
      error: "Secret RESEND_API_KEY manquant. Supabase → Settings → Edge Functions → Secrets.",
    }, 500);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: "Corps JSON invalide" }, 400);
  }

  const domain = String(payload.domain || "").trim().toLowerCase().replace(/^@/, "");
  const action = String(payload.action || "setup");

  if (!domain) return json({ ok: false, error: "Domaine manquant" }, 400);
  if (!isValidDomain(domain)) return json({ ok: false, error: "Nom de domaine invalide : " + domain }, 400);

  try {
    // 1. Retrouve le domaine s'il existe déjà chez Resend
    let domainObj: Record<string, unknown> | null = null;
    const listRes = await resend("/domains");
    if (listRes.ok) {
      const list = await listRes.json().catch(() => ({}));
      const arr = (list?.data || list || []) as Record<string, unknown>[];
      domainObj = arr.find((d) => String(d.name).toLowerCase() === domain) || null;
    }

    // 2. action "setup" : crée le domaine s'il n'existe pas encore
    if (action === "setup" && !domainObj) {
      const createRes = await resend("/domains", {
        method: "POST",
        body: JSON.stringify({ name: domain }),
      });
      const created = await createRes.json().catch(() => ({}));
      if (!createRes.ok) {
        const msg = created?.message || created?.error || `Resend HTTP ${createRes.status}`;
        return json({ ok: false, error: "Création domaine : " + msg }, 502);
      }
      domainObj = created;
    }

    if (!domainObj) {
      return json({ ok: false, error: "Domaine non trouvé chez Resend. Lance l'action « setup » d'abord." }, 404);
    }

    const id = String(domainObj.id);

    // 3. action "verify" : déclenche une revérification DNS
    if (action === "verify") {
      await resend(`/domains/${id}/verify`, { method: "POST" }).catch(() => {});
    }

    // 4. Récupère l'état détaillé (statut + enregistrements DNS frais)
    const detailRes = await resend(`/domains/${id}`);
    const detail = await detailRes.json().catch(() => domainObj) as Record<string, unknown>;
    const status = String(detail.status || domainObj.status || "pending");
    const records = normalizeRecords((detail.records || []) as unknown[]);

    const verified = status === "verified";
    return json({
      ok: true,
      domain,
      id,
      status,                       // not_started | pending | verified | failed | temporary_failure
      verified,
      records,                      // enregistrements DNS à coller chez le registrar du client
      hint: verified
        ? "Domaine vérifié ✓ — le client peut désormais envoyer depuis " + domain
        : "Ajoute ces enregistrements DNS chez le registrar du domaine, puis relance « Vérifier » (propagation : quelques minutes à 24 h).",
    });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 502);
  }
});
