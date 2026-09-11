// ═══════════════════════════════════════════════════════════════════
// ONIQ PILOTAGE — les retours
//
// Brevo nous dit ce qu'il advient de chaque mail : livré, rebondi,
// bloqué, signalé comme indésirable, désabonné. Cette fonction reçoit
// ces événements et les range dans ls_retours, puis la base fait le
// reste : le rebond compte sur la séquence, la plainte sort le contact
// pour toujours, la boîte voit son taux monter.
//
// Deux portes, sur la même adresse :
//   ?type=evenements   les webhooks transactionnels de Brevo
//   ?type=reponses     le parsing entrant de Brevo (réponses par mail),
//                      facultatif : il demande un sous-domaine dédié.
//
// La porte est fermée par un jeton : ?jeton=…, comparé au secret
// RETOURS_JETON. Sans jeton juste, rien n'est écrit. La fonction se
// déploie avec la vérification JWT désactivée (Brevo n'a pas de jeton
// Supabase), c'est le jeton d'URL qui garde la porte.
// ═══════════════════════════════════════════════════════════════════

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const CLE_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const JETON = Deno.env.get("RETOURS_JETON") ?? "";
const BREVO = Deno.env.get("BREVO_API_KEY") ?? "";

const H = {
  apikey: CLE_SERVICE,
  Authorization: `Bearer ${CLE_SERVICE}`,
  "Content-Type": "application/json",
};

async function rpc(nom: string, corps: unknown) {
  const r = await fetch(`${URL_BASE}/rest/v1/rpc/${nom}`, {
    method: "POST", headers: H, body: JSON.stringify(corps),
  });
  if (!r.ok) throw new Error(`${nom} ${r.status} ${await r.text()}`);
  return await r.json().catch(() => null);
}
async function lire(table: string, q: string) {
  const r = await fetch(`${URL_BASE}/rest/v1/${table}?${q}`, { headers: H });
  if (!r.ok) throw new Error(`${table} ${r.status} ${await r.text()}`);
  return await r.json();
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Les noms d'événements de Brevo, ramenés aux nôtres. Brevo écrit
// tantôt hardBounce, tantôt hard_bounce selon l'endroit : on gomme.
function traduire(ev: string): string {
  const e = String(ev ?? "").toLowerCase().replace(/[^a-z]/g, "");
  if (e === "delivered") return "livre";
  if (e === "hardbounce") return "rebond_dur";
  if (e === "softbounce" || e === "deferred") return "rebond_doux";
  if (e === "blocked" || e === "invalidemail" || e === "invalid" || e === "error") return "bloque";
  if (e === "spam" || e === "complaint") return "plainte";
  if (e === "unsubscribed" || e === "unsubscribe") return "desabonne";
  // Ce qui dit l'intérêt, et qu'on jetait : une ouverture, un clic.
  // Brevo écrit « opened », « uniqueOpened », « click », « clicks ».
  if (e === "opened" || e === "uniqueopened" || e === "open") return "ouvert";
  if (e === "click" || e === "clicks" || e === "clicked") return "clic";
  return "autre";
}

// L'identifiant de notre ligne, retrouvé dans les étiquettes.
function envoiDepuisTags(tags: unknown): string | null {
  const l = Array.isArray(tags) ? tags : (typeof tags === "string" ? [tags] : []);
  for (const t of l) {
    const m = /^envoi:([0-9a-f-]{36})$/i.exec(String(t));
    if (m && UUID.test(m[1])) return m[1];
  }
  return null;
}

async function unEvenement(ev: any) {
  const evenement = traduire(ev?.event);
  // Une ouverture et un clic ne vont pas au journal des retours, qui
  // sert à juger la délivrabilité : ils se posent sur la fiche, et
  // c'est eux qui remplissent la file des chauds.
  if (evenement === "autre") return;
  const envoiId = envoiDepuisTags(ev?.tags ?? ev?.tag);
  const messageId = String(ev?.["message-id"] ?? ev?.messageId ?? "");
  const motif = String(ev?.reason ?? ev?.error ?? "").slice(0, 300);
  await rpc("ls_retour_enregistrer", {
    p_evenement: evenement,
    p_email: String(ev?.email ?? "").toLowerCase().trim(),
    p_message_id: messageId,
    p_envoi_id: envoiId,
    p_motif: motif,
    p_brut: { event: ev?.event, date: ev?.date, ts: ev?.ts, subject: ev?.subject,
              sending_ip: ev?.sending_ip, tags: ev?.tags ?? ev?.tag, reason: ev?.reason },
  });
}

// Une réponse arrivée par le parsing entrant : on retrouve la
// séquence par l'adresse de l'expéditeur. « STOP » en tête du message
// ou dans l'objet, c'est un désabonnement ; le reste, une réponse.
// Dans les deux cas, le message est renvoyé à la boîte qui a écrit,
// pour que personne ne rate une réponse.
async function uneReponse(item: any) {
  const de = String(item?.From?.Address ?? item?.from?.address ?? "").toLowerCase().trim();
  if (!de) return;
  const objet = String(item?.Subject ?? item?.subject ?? "");
  const texte = String(item?.ExtractedMarkdownMessage ?? item?.RawTextBody ?? item?.text ?? "");
  const stop = /^\s*stop\b/i.test(texte) || /\bstop\b/i.test(objet);
  const seqs = await lire("ls_sequences",
    `select=id,boite_id,campagne_id&email=ilike.${encodeURIComponent(de)}&statut=eq.en_cours&order=cree_le.desc&limit=1`);
  if (seqs.length) {
    await rpc("ls_sequence_sortie", { p_id: seqs[0].id, p_sortie: stop ? "stop" : "mail" });
    await rpc("ls_retour_enregistrer", {
      p_evenement: stop ? "desabonne" : "reponse", p_email: de, p_message_id: "",
      p_envoi_id: null, p_motif: objet.slice(0, 200),
      p_brut: { sequence_id: seqs[0].id, campagne_id: seqs[0].campagne_id },
    });
  }
  // Transmettre à la personne : la boîte de la séquence, sinon la
  // première boîte active de la maison, sinon rien.
  if (!BREVO) return;
  let dest = "";
  if (seqs.length && seqs[0].boite_id) {
    const b = await lire("ls_boites", `select=adresse,proprietaire_email&id=eq.${seqs[0].boite_id}&limit=1`);
    dest = String(b[0]?.proprietaire_email || b[0]?.adresse || "");
  }
  if (!dest) {
    const a = Array.isArray(item?.To) ? item.To[0]?.Address : "";
    if (a) {
      const b = await lire("ls_boites", `select=adresse,proprietaire_email&or=(adresse.ilike.${encodeURIComponent(String(a))},adresse_envoi.ilike.${encodeURIComponent(String(a))})&limit=1`);
      dest = String(b[0]?.proprietaire_email || b[0]?.adresse || "");
    }
  }
  if (!dest) return;
  await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": BREVO, "Content-Type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: { name: "ONIQ Pilotage", email: dest },
      to: [{ email: dest }],
      replyTo: { email: de, name: String(item?.From?.Name ?? "") },
      subject: `Réponse de ${de} : ${objet || "(sans objet)"}`,
      textContent: `${stop ? "STOP reçu, le contact est sorti de toutes les campagnes.\n\n" : ""}${texte}`,
    }),
  }).then((r) => r.text()).catch(() => "");
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (!JETON || url.searchParams.get("jeton") !== JETON) {
    return new Response(JSON.stringify({ ok: false, erreur: "jeton absent ou faux" }),
      { status: 403, headers: { "Content-Type": "application/json" } });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: true, note: "ONIQ Pilotage écoute." }),
      { headers: { "Content-Type": "application/json" } });
  }
  let corps: any = null;
  try { corps = await req.json(); } catch { corps = null; }
  if (!corps) {
    return new Response(JSON.stringify({ ok: false, erreur: "corps illisible" }),
      { status: 400, headers: { "Content-Type": "application/json" } });
  }
  const type = url.searchParams.get("type") ?? "evenements";
  let traites = 0;
  const erreurs: string[] = [];
  try {
    if (type === "reponses") {
      const items = Array.isArray(corps?.items) ? corps.items : [corps];
      for (const it of items) {
        try { await uneReponse(it); traites++; }
        catch (e) { erreurs.push(String((e as Error).message ?? e).slice(0, 160)); }
      }
    } else {
      const evs = Array.isArray(corps) ? corps : [corps];
      for (const ev of evs) {
        try { await unEvenement(ev); traites++; }
        catch (e) { erreurs.push(String((e as Error).message ?? e).slice(0, 160)); }
      }
    }
  } catch (e) {
    erreurs.push(String((e as Error).message ?? e).slice(0, 160));
  }
  // Brevo réessaie sur une erreur : on répond 200 dès qu'on a lu, et
  // on garde le détail pour nous.
  return new Response(JSON.stringify({ ok: erreurs.length === 0, traites, erreurs }),
    { headers: { "Content-Type": "application/json" } });
});
