// ═══════════════════════════════════════════════════════════════════
// ONIQ PILOTAGE — tirage des leads Companeo
//
// FACULTATIF POUR ONIQ. Ce connecteur ne sert que si un compte Companeo
// (place de marché de demandes de devis entre entreprises) est ouvert.
// Sans les secrets COMPANEO_USER et COMPANEO_PASS, il répond une erreur
// et ne touche à rien : on peut ne pas le déployer du tout. Les leads
// qu'il rapporte arrivent dans la maison « bornistes » (ONIQ Sur mesure).
//
// Companeo ne pousse rien : son webservice s'interroge. On l'appelle
// donc toutes les cinq minutes avec newleads=t, qui rend les leads
// jamais téléchargés et fait avancer leur compteur côté Companeo.
//
// Deux conséquences dont tout le reste découle :
//   — un lead rendu une fois ne sera plus rendu. On l'écrit en base
//     avant toute autre chose.
//   — si quelqu'un télécharge l'Excel depuis l'extranet, ces leads-là
//     ne repasseront jamais par ici. Personne ne touche à l'extranet.
//
// Le rattrapage se fait par dates (from/to), qui ne consomme pas le
// compteur : /companeo?jours=7
// ═══════════════════════════════════════════════════════════════════

const URL_WS   = "https://fac.companeo.com/w3s_get_rfq.php";
const SB       = Deno.env.get("SUPABASE_URL")!;
const SERVICE  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const USER     = Deno.env.get("COMPANEO_USER") ?? "";
const PASS     = Deno.env.get("COMPANEO_PASS") ?? "";
const SOURCE   = "Companeo";

const entetes = {
  "apikey": SERVICE,
  "Authorization": `Bearer ${SERVICE}`,
  "Content-Type": "application/json",
};

async function lire(chemin: string) {
  const r = await fetch(`${SB}/rest/v1/${chemin}`, { headers: entetes });
  return r.ok ? await r.json() : [];
}
async function ecrire(table: string, corps: unknown) {
  const r = await fetch(`${SB}/rest/v1/${table}`, {
    method: "POST",
    headers: { ...entetes, Prefer: "return=representation" },
    body: JSON.stringify(corps),
  });
  if (!r.ok) throw new Error(`${table} : ${await r.text()}`);
  return await r.json();
}
async function modifier(table: string, filtre: string, corps: unknown) {
  await fetch(`${SB}/rest/v1/${table}?${filtre}`, {
    method: "PATCH", headers: entetes, body: JSON.stringify(corps),
  });
}

// ── Lecture du XML ─────────────────────────────────────────────────
// Le flux est plat et documenté : une balise par champ, du CDATA
// partout. Un analyseur de trois lignes vaut mieux ici qu'une
// dépendance qu'il faudrait suivre.
function nettoie(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .trim();
}
function champ(bloc: string, tag: string): string {
  const m = bloc.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, "i"));
  return m ? nettoie(m[1]) : "";
}
function questions(bloc: string): { q: string; r: string }[] {
  const out: { q: string; r: string }[] = [];
  const zone = bloc.match(/<questionnaire>([\s\S]*?)<\/questionnaire>/i);
  if (!zone) return out;
  for (const m of zone[1].matchAll(/<question>([\s\S]*?)<\/question>/gi)) {
    const q = champ(m[1], "value"), r = champ(m[1], "reponse");
    if (q) out.push({ q, r });
  }
  return out;
}

// ── Le tirage ──────────────────────────────────────────────────────
async function tirer(parametres: string) {
  const bilan = { recus: 0, crees: 0, doublons: 0, erreur: "" };

  const rep = await fetch(`${URL_WS}?${parametres}`, {
    headers: { "Authorization": "Basic " + btoa(`${USER}:${PASS}`) },
  });
  if (rep.status === 401 || rep.status === 403) {
    throw new Error("Companeo refuse les identifiants (HTTP " + rep.status +
      "). Vérifiez COMPANEO_USER et COMPANEO_PASS dans les secrets.");
  }
  if (!rep.ok) throw new Error("Companeo a répondu HTTP " + rep.status);

  const xml = await rep.text();
  const blocs = [...xml.matchAll(/<demande>([\s\S]*?)<\/demande>/gi)].map((m) => m[1]);
  bilan.recus = blocs.length;

  // Le commercial à qui les leads Companeo reviennent.
  const src = await lire(`ls_sources?select=owner_email,delai_min&nom=eq.${encodeURIComponent(SOURCE)}&limit=1`);
  const proprio = (src[0]?.owner_email ?? "") as string;

  for (const b of blocs) {
    try {
      const ref   = champ(b, "lead_id") || champ(b, "id");
      const tel   = champ(b, "telephone") || champ(b, "mobile");
      const nom   = [champ(b, "prenom"), champ(b, "nom")].filter(Boolean).join(" ");
      const soc   = champ(b, "raison_sociale") || nom || "Lead Companeo";
      const qs    = questions(b);

      // Déjà rentré ? Le lead_id tranche, pas le nom de la société.
      if (ref) {
        const deja = await lire(
          `ls_prospects?select=id&source=eq.${encodeURIComponent(SOURCE)}&ref_source=eq.${encodeURIComponent(ref)}&limit=1`);
        if (deja.length) { bilan.doublons++; continue; }
      }

      const notes = [
        champ(b, "commentaire"),
        champ(b, "comment_companeo"),
        [champ(b, "poste"), champ(b, "fonction")].filter(Boolean).join(" · "),
        qs.slice(0, 3).map((x) => `${x.q} : ${x.r}`).join(" | "),
      ].filter(Boolean).join(" — ").slice(0, 900);

      const effTexte = champ(b, "effectif");
      const effNum   = parseInt(effTexte.replace(/\D/g, ""), 10);

      const fiche: Record<string, unknown> = {
        societe: soc,
        activite: "bornistes",
        ville: champ(b, "ville"),
        code_postal: champ(b, "code_postal"),
        effectif: effTexte,
        effectif_num: Number.isFinite(effNum) ? effNum : 0,
        dirigeant: nom,
        tel: tel || null,
        email: champ(b, "email") || null,
        source: SOURCE,
        ref_source: ref || null,
        est_lead: true,
        origine_lead: "formulaire",
        etape: "A contacter",
        owner_email: proprio,
        note: notes,
        prochaine: "RAPPELER TOUT DE SUITE",
        rappel_le: new Date().toISOString(),
      };

      // Même numéro déjà dans la maison : on réveille la fiche au lieu
      // d'en créer une deuxième. Deux commerciaux sur le même numéro à
      // dix minutes d'intervalle, c'est une affaire déjà perdue.
      let id: string | null = null;
      if (tel) {
        const memeTel = await lire(
          `ls_prospects?select=id&tel=eq.${encodeURIComponent(tel)}&limit=1`);
        if (memeTel.length) {
          id = memeTel[0].id;
          await modifier("ls_prospects", `id=eq.${id}`, {
            est_lead: true, ref_source: ref || null, source: SOURCE,
            appel_resultat: null, etape: "A contacter", owner_email: proprio,
            rappel_le: new Date().toISOString(),
            prochaine: "Nouvelle demande Companeo — rappeler tout de suite",
            note: notes,
          });
          bilan.doublons++;
        }
      }
      if (!id) {
        const cree = await ecrire("ls_prospects", fiche);
        id = cree?.[0]?.id ?? null;
        bilan.crees++;
      }

      // Companeo a déjà posé des questions. Les reposer au téléphone,
      // c'est donner l'impression qu'on n'a pas lu la demande.
      if (id && qs.length) {
        const recap = ["CE QUE COMPANEO A DÉJÀ DEMANDÉ", ""]
          .concat(qs.map((x) => `  ${x.q} : ${x.r || "—"}`)).join("\n");
        await fetch(`${SB}/rest/v1/ls_qualif?on_conflict=prospect_id`, {
          method: "POST",
          headers: { ...entetes, Prefer: "resolution=merge-duplicates" },
          body: JSON.stringify({
            prospect_id: id, societe: soc, par: SOURCE, recap,
            reponses: { companeo: qs },
            maj_le: new Date().toISOString(),
          }),
        });
      }
    } catch (e) {
      bilan.erreur = String((e as Error).message ?? e).slice(0, 400);
    }
  }
  return bilan;
}

Deno.serve(async (req) => {
  if (!USER || !PASS) {
    return new Response(JSON.stringify({
      ok: false,
      erreur: "COMPANEO_USER et COMPANEO_PASS ne sont pas posés dans les secrets de la fonction.",
    }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  // Par défaut : ce qui n'a jamais été téléchargé.
  // Rattrapage sur n jours : ?jours=7 — ne touche pas au compteur.
  const url = new URL(req.url);
  const jours = parseInt(url.searchParams.get("jours") ?? "", 10);
  const parametres = Number.isFinite(jours) && jours > 0 && jours <= 120
    ? `days_ago=${jours}`
    : "newleads=t";

  let bilan = { recus: 0, crees: 0, doublons: 0, erreur: "" };
  try {
    bilan = await tirer(parametres);
  } catch (e) {
    bilan.erreur = String((e as Error).message ?? e).slice(0, 400);
  }

  try {
    await ecrire("ls_tirages", { source: SOURCE, ...bilan });
    await modifier("ls_sources", `nom=eq.${encodeURIComponent(SOURCE)}`, {
      dernier_tirage: new Date().toISOString(),
      dernier_bilan: bilan.erreur
        ? `échec : ${bilan.erreur}`
        : `${bilan.recus} reçus · ${bilan.crees} créés · ${bilan.doublons} déjà connus`,
      statut: bilan.erreur ? "en_test" : "actif",
    });
  } catch { /* le journal ne doit jamais faire échouer le tirage */ }

  return new Response(JSON.stringify({ ok: !bilan.erreur, mode: parametres, ...bilan }), {
    status: bilan.erreur ? 502 : 200,
    headers: { "Content-Type": "application/json" },
  });
});
