// ═══════════════════════════════════════════════════════════════════
// ONIQ PILOTAGE — l'engrenage à partenaires
//
// Deux gestes, appelés depuis le CRM :
//
//   { action: "chercher", activite, naf, departement }
//       interroge le registre public des entreprises, crée les fiches
//       qui manquent, ignore celles qu'on a déjà. Gratuit, sans clé.
//
//   { action: "numero", id }
//       cherche le numéro de téléphone d'une fiche précise chez
//       Google, et l'écrit. Payant, donc jamais automatique : c'est le
//       commercial qui décide, fiche par fiche.
//
// Le registre ne publie aucun numéro de téléphone : c'est pour ça que
// les deux gestes sont séparés. On ratisse large gratuitement, on ne
// paie que pour ce qu'on garde.
//
// Aucune clé n'est écrite ici. Elles arrivent par les secrets du
// projet (Edge Functions → Secrets).
// ═══════════════════════════════════════════════════════════════════

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const CLE_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// La clé anonyme ne sert qu'à faire vérifier par la base, avec le
// jeton de l'appelant, qu'il fait bien partie de l'équipe.
const CLE_ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const CLE_GOOGLE = Deno.env.get("GOOGLE_PLACES_KEY") ?? "";

const REGISTRE = "https://recherche-entreprises.api.gouv.fr/search";
const PLACES = "https://places.googleapis.com/v1/places:searchText";

const H = {
  apikey: CLE_SERVICE,
  Authorization: `Bearer ${CLE_SERVICE}`,
  "Content-Type": "application/json",
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function repondre(corps: unknown, code = 200) {
  return new Response(JSON.stringify(corps), {
    status: code,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function lire(table: string, q: string) {
  const r = await fetch(`${URL_BASE}/rest/v1/${table}?${q}`, { headers: H });
  if (!r.ok) throw new Error(`${table} ${r.status} ${await r.text()}`);
  return await r.json();
}
async function ecrire(table: string, corps: unknown) {
  const r = await fetch(`${URL_BASE}/rest/v1/${table}`, {
    method: "POST",
    headers: { ...H, Prefer: "return=representation,resolution=ignore-duplicates" },
    body: JSON.stringify(corps),
  });
  if (!r.ok && r.status !== 409) throw new Error(`${table} ${r.status} ${await r.text()}`);
  return r.status === 409 ? [] : await r.json().catch(() => []);
}
// Combien de lignes répondent à ce filtre. PostgREST le dit dans un
// en-tête, sans rapatrier les lignes.
async function compter(table: string, filtre: string): Promise<number> {
  const r = await fetch(`${URL_BASE}/rest/v1/${table}?select=id&limit=1&${filtre}`, {
    headers: { ...H, Prefer: "count=exact" },
  });
  const cr = r.headers.get("content-range") ?? "0/0";
  return parseInt(cr.split("/")[1], 10) || 0;
}

// L'insertion des fiches, ligne par ligne en cas de refus groupé. Une
// fiche qui heurte une contrainte ne doit pas emporter les dix-sept
// autres, et on veut savoir laquelle et pourquoi.
async function insererFiches(lignes: unknown[]): Promise<{ crees: number; refus: string[] }> {
  const refus: string[] = [];
  let crees = 0;
  for (let i = 0; i < lignes.length; i += 50) {
    const lot = lignes.slice(i, i + 50);
    const r = await fetch(`${URL_BASE}/rest/v1/ls_prescripteurs`, {
      method: "POST",
      headers: { ...H, Prefer: "return=representation" },
      body: JSON.stringify(lot),
    });
    if (r.ok) { crees += ((await r.json()) as unknown[]).length; continue; }
    const txt = (await r.text()).slice(0, 300);
    // Refus groupé : on reprend une par une pour ne perdre que les
    // fautives, et pour savoir ce que la base reproche.
    for (const l of lot) {
      const u = await fetch(`${URL_BASE}/rest/v1/ls_prescripteurs`, {
        method: "POST",
        headers: { ...H, Prefer: "return=representation" },
        body: JSON.stringify([l]),
      });
      if (u.ok) { crees += ((await u.json()) as unknown[]).length; }
      else if (refus.length < 3) refus.push((await u.text()).slice(0, 200));
      else await u.text();
    }
    if (!refus.length) refus.push(txt);
  }
  return { crees, refus };
}

async function majr(table: string, filtre: string, corps: unknown) {
  await fetch(`${URL_BASE}/rest/v1/${table}?${filtre}`, {
    method: "PATCH", headers: H, body: JSON.stringify(corps),
  });
}

// ─── Qui appelle ───────────────────────────────────────────────────
// Cette fonction écrit dans le fichier avec la clé service : elle ne
// doit répondre qu'à l'équipe. On ne juge pas le jeton nous-mêmes, on
// le tend à la base avec la clé anonyme, et c'est ls_est_staff() qui
// tranche. Un jeton faux ou expiré est refusé par PostgREST avant
// même d'atteindre la fonction.

function jetonDe(req: Request): string {
  return (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
}

async function estStaff(jeton: string): Promise<boolean> {
  // Le moteur appelle cette fonction depuis le cron, avec la clé
  // service : il n'a pas de jeton d'équipe et il n'en aura jamais.
  // Cette clé ne sort pas des secrets de Supabase, personne d'autre
  // ne l'a.
  if (jeton && CLE_SERVICE && jeton === CLE_SERVICE) return true;
  if (!jeton || !CLE_ANON) return false;
  const stop = new AbortController();
  const minuteur = setTimeout(() => stop.abort(), 15000);
  try {
    const r = await fetch(`${URL_BASE}/rest/v1/rpc/ls_est_staff`, {
      method: "POST",
      headers: { apikey: CLE_ANON, Authorization: `Bearer ${jeton}`, "Content-Type": "application/json" },
      body: "{}",
      signal: stop.signal,
    });
    if (!r.ok) { await r.text().catch(() => ""); return false; }
    return (await r.json()) === true;
  } catch { return false; }
  finally { clearTimeout(minuteur); }
}

// L'adresse de l'appelant se lit dans le jeton, pas dans le corps de
// la requête : ce qu'on tape dans un corps, on peut y mettre n'importe
// quel nom. La signature n'est pas vérifiée ici — elle vient de l'être
// par la base, dans l'appel à ls_est_staff() qui a réussi.
function emailDuJeton(jeton: string): string {
  try {
    const partie = jeton.split(".")[1] ?? "";
    const b64 = partie.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(partie.length / 4) * 4, "=");
    const json = new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));
    return String(JSON.parse(json).email ?? "").toLowerCase().trim();
  } catch { return ""; }
}

// ─── Où on accepte d'aller lire ────────────────────────────────────
// Cette fonction tourne chez Supabase, avec accès au réseau interne.
// Une fiche dont le « site » serait 127.0.0.1, localhost ou un nom en
// .internal ferait lire ce réseau-là au lieu du web : on n'accepte
// qu'un vrai nom de domaine public, en http ou https.
function urlSure(u: string): boolean {
  let x: URL;
  try { x = new URL(u); } catch { return false; }
  if (x.protocol !== "http:" && x.protocol !== "https:") return false;
  const h = x.hostname.toLowerCase().replace(/\.$/, "");
  if (!h || h === "localhost" || h.endsWith(".localhost")) return false;
  if (h.endsWith(".local") || h.endsWith(".internal")) return false;
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(h)) return false;     // IPv4 littérale
  if (h.startsWith("[") || h.includes(":")) return false;  // IPv6 littérale
  if (/^0x[0-9a-f]+$/i.test(h) || /^\d+$/.test(h)) return false; // IP déguisée
  return h.includes(".");
}

// ─── Le registre ───────────────────────────────────────────────────
// Il rend le nom, l'adresse, l'effectif et les dirigeants. Jamais de
// téléphone : la loi ne l'y oblige pas et l'INSEE ne le collecte pas.

type Fiche = {
  nom: string; siren: string; naf: string; contact: string;
  adresse: string; code_postal: string; ville: string; effectif: string;
  tel?: string; email?: string; site?: string;
};

// Le registre code les effectifs par tranche. Le libellé parle plus au
// commercial que le code : « 6 à 9 salariés » lui dit s'il aura le
// patron au téléphone ou un standard.
const TRANCHES: Record<string, string> = {
  "NN": "", "00": "0 salarié", "01": "1 ou 2 salariés", "02": "3 à 5 salariés",
  "03": "6 à 9 salariés", "11": "10 à 19 salariés", "12": "20 à 49 salariés",
  "21": "50 à 99 salariés", "22": "100 à 199 salariés", "31": "200 à 249 salariés",
  "32": "250 à 499 salariés", "41": "500 à 999 salariés", "42": "1 000 à 1 999 salariés",
  "51": "2 000 à 4 999 salariés", "52": "5 000 à 9 999 salariés", "53": "10 000 salariés et plus",
};

function nomDirigeant(d: unknown): string {
  const l = Array.isArray(d) ? d : [];
  for (const x of l) {
    const o = x as Record<string, string>;
    const p = [o.prenoms, o.nom].filter(Boolean).join(" ").trim();
    if (p) return p.split(/\s+/).slice(0, 3).join(" ");
  }
  return "";
}

// Le registre attend le code NAF ponctue : 69.20Z, pas 6920Z. On le
// stocke sans point parce que c'est ce que les gens tapent, et on le
// ponctue ici. C'est exactement ce qui faisait repondre 400.
function nafPonctue(brut: string): string {
  const n = String(brut ?? "").toUpperCase().replace(/[^0-9A-Z]/g, "");
  return n.length >= 4 ? `${n.slice(0, 2)}.${n.slice(2)}` : n;
}

async function interrogerRegistre(naf: string, departement: string,
                                  depart = 1, budget = 70000): Promise<{ fiches: Fiche[]; suivante: number | null }> {
  const out: Fiche[] = [];
  const debut = Date.now();
  const code = nafPonctue(naf);
  // Deux façons d'écrire la même question. Si la première déplaît au
  // registre, on essaie la seconde avant d'abandonner : un filtre
  // refusé ne doit pas faire échouer toute la recherche.
  const formes = [
    (page: number) => `${REGISTRE}?activite_principale=${encodeURIComponent(code)}`
      + `&departement=${encodeURIComponent(departement)}`
      + `&etat_administratif=A&per_page=25&page=${page}`,
    (page: number) => `${REGISTRE}?activite_principale=${encodeURIComponent(code)}`
      + `&departement=${encodeURIComponent(departement)}`
      + `&per_page=25&page=${page}`,
  ];

  // Vingt secondes par appel : un registre qui rame ne doit pas tenir
  // la fonction jusqu'à ce que Supabase la coupe sans un mot.
  const registre = async (url: string) => {
    const stop = new AbortController();
    const minuteur = setTimeout(() => stop.abort(), 20000);
    try {
      return await fetch(url, { headers: { Accept: "application/json" }, signal: stop.signal });
    } finally { clearTimeout(minuteur); }
  };

  let forme = -1, dernier = "";
  for (let i = 0; i < formes.length; i++) {
    let r: Response;
    try { r = await registre(formes[i](1)); }
    catch (e) { dernier = (e as Error).name === "AbortError" ? "pas de réponse en vingt secondes" : String((e as Error).message ?? e); continue; }
    if (r.ok) { forme = i; await r.text().catch(() => ""); break; }
    dernier = `${r.status} ${(await r.text()).slice(0, 220)}`;
  }
  if (forme < 0)
    throw new Error(`Le registre refuse la recherche pour ${code} dans le département ${departement}. Réponse : ${dernier}`);

  // Le registre pagine par 25 et ne s'arrête pas à la huitième page :
  // un métier dans un département peuplé, ce sont des milliers
  // d'établissements. On avance tant qu'il en donne et tant que la
  // fonction a du temps devant elle, puis on rend la page suivante
  // pour que l'appelant reprenne là où on s'est arrêté. Un plafond
  // arbitraire, c'est un fichier tronqué que personne ne remarque.
  let suivante: number | null = null;
  for (let page = depart; page <= depart + 400; page++) {
    if (Date.now() - debut > budget) { suivante = page; break; }
    let r: Response;
    try { r = await registre(formes[forme](page)); } catch { break; }
    if (!r.ok) { await r.text().catch(() => ""); break; }
    const j = await r.json();
    const res = (j.results ?? []) as Record<string, never>[];
    if (!res.length) break;
    for (const e of res) {
      const o = e as unknown as Record<string, unknown>;
      const siege = (o.siege ?? {}) as Record<string, string>;
      out.push({
        nom: String(o.nom_complet ?? o.nom_raison_sociale ?? "").trim(),
        siren: String(o.siren ?? ""),
        naf: String(o.activite_principale ?? code),
        contact: nomDirigeant(o.dirigeants),
        adresse: String(siege.adresse ?? "").replace(/\s+/g, " ").trim(),
        code_postal: String(siege.code_postal ?? ""),
        ville: String(siege.libelle_commune ?? ""),
        effectif: TRANCHES[String(o.tranche_effectif_salarie ?? "NN")] ?? "",
      });
    }
    if (res.length < 25) break;
    // Le registre tolère sept appels par seconde. On reste loin dessous :
    // rien ne presse, et un service public gratuit se ménage.
    await new Promise((r) => setTimeout(r, 160));
  }
  return { fiches: out.filter((f) => f.nom && f.siren), suivante };
}

// ─── L'annuaire ouvert ─────────────────────────────────────────────
// OpenStreetMap connaît une partie des établissements, et pour
// ceux-là il donne le téléphone, l'adresse et souvent le site. C'est
// incomplet par nature — il ne contient que ce que des gens ont
// cartographié — mais c'est libre, gratuit et réutilisable, et une
// fiche qui en sort est appelable tout de suite.

// Plusieurs serveurs rendent le même service. Le premier est le plus
// complet, les suivants prennent le relais quand il sature ou refuse.
const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.osm.ch/api/interpreter",
];
// Sans identification, le serveur public répond 406 et referme la
// porte : il ne veut pas de robots anonymes. On dit donc qui on est,
// ce qui est la moindre des politesses pour un service gratuit.
const SIGNATURE = "ONIQ-Pilotage/1.0 (+https://oniq.online)";

function telFr(brut: string): string {
  const n = String(brut ?? "").split(/[;,/]/)[0].replace(/[^\d+]/g, "");
  if (/^\+33/.test(n)) return "0" + n.slice(3);
  return n;
}

async function interrogerAnnuaire(osm: string, departement: string): Promise<Fiche[]> {
  const tags = String(osm ?? "").split(",").map((t) => t.trim()).filter(Boolean);
  if (!tags.length) throw new Error("Ce métier n’a pas encore d’équivalent dans l’annuaire ouvert.");

  // On ne demande plus seulement ceux qui ont un téléphone. Un
  // établissement qui n'a qu'un site web n'est pas perdu : son numéro
  // est presque toujours écrit sur ce site, et aller le lire ne coûte
  // rien. On prend donc tout, et on trie ensuite.
  const clauses = tags.flatMap((t) => {
    const [k, v] = t.split("=");
    // Un motif de nom, écrit « nom~comptab », attrape les
    // établissements que personne n'a pris la peine de catégoriser
    // proprement mais qui portent leur métier dans leur enseigne.
    if (k === "nom" && v) return [`nwr["name"~"${v}",i](area.d);`];
    if (!k || !v) return [];
    return [`nwr["${k}"="${v}"](area.d);`];
  }).join("\n");

  // Vingt-cinq secondes suffisent pour un département. Au-delà, le
  // serveur public a autre chose à faire, et une fonction Edge finit
  // par se faire couper sans rien dire : l'écran resterait sur
  // « Recherche… » indéfiniment.
  // Le département s'écrit sur deux chiffres dans la cartographie, et
  // le 69 est un cas à part : depuis 2015 il est coupé en deux, le
  // Rhône (69D) et la Métropole de Lyon (69M). Chercher « 69 » tout
  // court ne trouvait donc aucun territoire, et la recherche rendait
  // zéro sans la moindre erreur. On accepte les trois écritures.
  const dep = departement.length === 1 ? "0" + departement : departement;
  const q = `[out:json][timeout:25];\n`
    + `area["ref:INSEE"~"^${dep}(D|M)?$"]["admin_level"~"^(6|7)$"]->.d;\n`
    + `(\n${clauses}\n);\nout tags center 600;`;

  let j: Record<string, unknown> | null = null;
  let dernier = "";
  for (const url of OVERPASS) {
    const stop = new AbortController();
    const minuteur = setTimeout(() => stop.abort(), 32000);
    try {
      const r = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "application/json",
          "User-Agent": SIGNATURE,
        },
        body: "data=" + encodeURIComponent(q),
        signal: stop.signal,
      });
      if (r.ok) { j = await r.json(); clearTimeout(minuteur); break; }
      dernier = `${r.status} sur ${new URL(url).host} : ${(await r.text()).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim().slice(0, 160)}`;
    } catch (e) {
      const m = String((e as Error).name === "AbortError"
        ? "trop lent, abandonné au bout de trente secondes"
        : (e as Error).message ?? e);
      dernier = `${new URL(url).host} : ${m.slice(0, 120)}`;
    } finally {
      clearTimeout(minuteur);
    }
  }
  if (!j) throw new Error(`L’annuaire ouvert n’a pas répondu. ${dernier}`);

  const out: Fiche[] = [];
  const vus = new Set<string>();
  for (const e of ((j.elements ?? []) as Record<string, never>[])) {
    const t = ((e as unknown as Record<string, unknown>).tags ?? {}) as Record<string, string>;
    const nom = String(t.name ?? t["operator"] ?? "").trim();
    const tel = telFr(t.phone ?? t["contact:phone"] ?? t["contact:mobile"] ?? t["phone:mobile"] ?? "");
    const site = String(t["contact:website"] ?? t["website"] ?? "").trim();
    // Sans nom, rien à appeler. Sans téléphone ni site, rien à en
    // tirer non plus : on ne remplit pas le fichier de coquilles.
    if (!nom || (tel.length < 9 && !site)) continue;
    if (tel && vus.has(tel)) continue;
    if (tel) vus.add(tel);
    const rue = [t["addr:housenumber"], t["addr:street"]].filter(Boolean).join(" ");
    out.push({
      nom,
      siren: "",
      naf: "",
      contact: "",
      adresse: rue,
      code_postal: String(t["addr:postcode"] ?? ""),
      ville: String(t["addr:city"] ?? ""),
      effectif: "",
      tel,
      email: String(t["contact:email"] ?? t["email"] ?? ""),
      site,
    });
  }
  return out;
}

// ─── Le numéro de téléphone ────────────────────────────────────────
// Google le publie, légalement, contre paiement. C'est la seule voie
// propre : aspirer Pages Jaunes ou Maps est interdit par leurs
// conditions, et déjà sanctionné en justice.

async function unePasse(requete: string): Promise<{ tel: string; site: string }> {
  // Vingt secondes : Google répond en général en moins d'une, et un
  // lot de soixante fiches ne doit pas mourir sur une seule qui pend.
  const stop = new AbortController();
  const minuteur = setTimeout(() => stop.abort(), 20000);
  let r: Response;
  try {
    r = await fetch(PLACES, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": CLE_GOOGLE,
        "X-Goog-FieldMask":
          "places.nationalPhoneNumber,places.websiteUri,places.displayName,places.formattedAddress",
      },
      body: JSON.stringify({
        textQuery: requete,
        languageCode: "fr",
        regionCode: "FR",
        maxResultCount: 1,
      }),
      signal: stop.signal,
    });
  } catch (e) {
    throw new Error((e as Error).name === "AbortError"
      ? "Google n’a pas répondu en vingt secondes."
      : `Google injoignable : ${String((e as Error).message ?? e).slice(0, 120)}`);
  } finally { clearTimeout(minuteur); }
  if (!r.ok) throw new Error(`Google a répondu ${r.status}. ${(await r.text()).slice(0, 200)}`);
  const j = await r.json();
  const p = (j.places ?? [])[0] as Record<string, string> | undefined;
  return {
    tel: p?.nationalPhoneNumber ? p.nationalPhoneNumber.replace(/\s+/g, " ").trim() : "",
    site: p?.websiteUri ?? "",
  };
}

// Deux tentatives : l'adresse complète, puis le seul nom avec la
// ville. Un cabinet déménagé, ou dont l'adresse du siège diffère de
// celle du bureau, se rate à la première et se trouve à la seconde.
async function chercherNumero(nom: string, adresse: string, ville: string) {
  if (!CLE_GOOGLE) throw new Error("Aucune clé Google n’est posée dans les secrets du projet.");
  const essais = [`${nom} ${adresse}`.trim(), `${nom} ${ville}`.trim()]
    .filter((x, i, l) => x && l.indexOf(x) === i);
  for (const e of essais) {
    const r = await unePasse(e);
    if (r.tel) return r;
  }
  return { tel: "", site: "" };
}

// ─── Lire un numéro sur le site d'une entreprise ───────────────────
// Un numéro français s'écrit de six façons, toutes reconnaissables.
// On refuse ce qui n'en est pas un : un SIRET, une date, un prix.

function numeroDansTexte(html: string): string {
  const texte = html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ");

  // Les liens tel: sont la source la plus sûre : c'est l'entreprise
  // elle-même qui déclare son numéro pour qu'on l'appelle.
  const lien = html.match(/href=["']tel:([^"']+)["']/i);
  if (lien) {
    const n = telFr(lien[1]);
    if (/^0[1-9]\d{8}$/.test(n)) return n;
  }

  const trouves = texte.match(/(?:\+33\s?|0)[1-9](?:[\s.\-]?\d{2}){4}/g) ?? [];
  for (const brut of trouves) {
    const n = telFr(brut);
    if (!/^0[1-9]\d{8}$/.test(n)) continue;
    if (/^0(8|89)/.test(n)) continue;          // numéros surtaxés
    return n;
  }
  return "";
}

// ─── L'e-mail, et lequel ───────────────────────────────────────────
// Un site publie souvent plusieurs adresses. Toutes ne se valent pas :
// « partenariats@ » ou « direction@ » vaut de l'or, « prenom.nom@ »
// atteint une personne, « contact@ » atteint un standard, et
// « noreply@ » n'atteint personne. On note chaque adresse et on garde
// la meilleure, en refusant celles qui ne sont pas du domaine du site.

const MAILS_INUTILES = /(noreply|no-reply|nepasrepondre|webmaster|postmaster|dpo|rgpd|recrutement|candidature|carriere|job|stage|presse|press|support|abuse|facture|billing|newsletter|unsubscribe|desinscription|example|sentry|wixpress|godaddy|squarespace)/i;

function scoreMail(m: string): number {
  const l = m.toLowerCase();
  const local = l.split("@")[0];
  if (MAILS_INUTILES.test(l)) return -1;
  if (/(partenariat|partenaire|partnership|partner)/.test(local)) return 100;
  if (/^(direction|dg|pdg|gerant|gerance|president|presidence|associe|associes|fondateur|ceo)/.test(local)) return 90;
  if (/^(commercial|business|developpement|bizdev|sales)/.test(local)) return 70;
  // prenom.nom, prenom-nom, p.nom : une personne, donc quelqu'un qui répond
  if (/^[a-z]+[._-][a-z]{2,}$/.test(local) && !/^(contact|info|accueil|bonjour|hello|cabinet|secretariat|admin|administration|compta|comptabilite|paie|social)$/.test(local)) return 60;
  if (/^(contact|bonjour|hello|accueil|cabinet|secretariat|info|infos)$/.test(local)) return 30;
  return 40;
}

function domaineDe(u: string): string {
  try { return new URL(/^https?:\/\//i.test(u) ? u : "https://" + u).hostname.replace(/^www\./i, "").toLowerCase(); }
  catch { return ""; }
}

function mailsDansTexte(html: string, domaine: string): { email: string; score: number } {
  // Les adresses écrites « prenom [at] domaine [dot] fr » pour tromper
  // les robots : on les remet d'aplomb, c'est nous le lecteur légitime.
  const t = html
    .replace(/\s*\[\s*at\s*\]\s*|\s*\(\s*at\s*\)\s*|\s+arobase\s+/gi, "@")
    .replace(/\s*\[\s*dot\s*\]\s*|\s*\(\s*dot\s*\)\s*/gi, ".");
  const trouves = new Set<string>();
  for (const l of t.match(/href=["']mailto:([^"'?]+)/gi) ?? [])
    trouves.add(l.replace(/^href=["']mailto:/i, "").trim());
  for (const m of t.match(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/gi) ?? []) trouves.add(m);

  let meilleur = "", score = -1;
  for (const brut of trouves) {
    const m = brut.toLowerCase().replace(/[.,;:]+$/, "");
    if (!/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/.test(m)) continue;
    if (/\.(png|jpg|jpeg|gif|svg|webp|css|js)$/.test(m)) continue;
    const dom = m.split("@")[1];
    // Une adresse d'un autre domaine, c'est l'agence web ou un
    // prestataire : elle ne nous mène pas au patron.
    if (domaine && dom !== domaine && !dom.endsWith("." + domaine) && !domaine.endsWith("." + dom)) continue;
    const sc = scoreMail(m);
    if (sc > score) { score = sc; meilleur = m; }
  }
  return { email: meilleur, score };
}

// Le directeur de la publication, c'est le patron : les mentions
// légales l'écrivent en toutes lettres, la loi l'y oblige.
function dirigeantDansTexte(html: string): string {
  const t = html.replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ");
  const motifs = [
    /[Dd]irect(?:eur|rice)(?:\s*\(?trice\)?)?\s+de\s+(?:la\s+)?[Pp]ublication\s*[:\-–]?\s*(?:M\.|Mme|Monsieur|Madame|Mr|Mlle)?\s*([A-ZÀ-Ý][a-zà-ÿ'\-]+(?:\s+[A-ZÀ-Ý][A-Za-zà-ÿ'\-]+){1,3})/,
    /(?:[Gg][ée]rant|[Pp]r[ée]sident|[Dd]irigeant|[Rr]epr[ée]sentant\s+l[ée]gal)(?:\s*\(?e\)?)?\s*[:\-–]\s*(?:M\.|Mme|Monsieur|Madame|Mr|Mlle)?\s*([A-ZÀ-Ý][a-zà-ÿ'\-]+(?:\s+[A-ZÀ-Ý][A-Za-zà-ÿ'\-]+){1,3})/,
  ];
  for (const m of motifs) {
    const r = t.match(m);
    if (r && r[1] && r[1].length <= 60 && !/soci[ée]t[ée]|sarl|sas|cabinet/i.test(r[1])) return r[1].trim();
  }
  return "";
}

type Trouvaille = { tel: string; email: string; score: number; contact: string };

async function lireSite(site: string): Promise<Trouvaille> {
  let base = String(site ?? "").trim();
  const vide: Trouvaille = { tel: "", email: "", score: -1, contact: "" };
  if (!base) return vide;
  if (!/^https?:\/\//i.test(base)) base = "https://" + base;
  if (!urlSure(base)) return vide;
  let racine = "";
  try { racine = new URL(base).origin; } catch { return vide; }
  const domaine = domaineDe(base);

  // L'accueil et le contact pour le téléphone, les mentions légales
  // pour le patron et souvent son adresse, l'équipe pour les noms.
  const pages = [base, racine + "/contact", racine + "/contact/", racine + "/nous-contacter",
                 racine + "/mentions-legales", racine + "/mentions-legales/",
                 racine + "/equipe", racine + "/a-propos", racine + "/le-cabinet"];
  const out: Trouvaille = { ...vide };
  let lues = 0;
  for (const u of pages) {
    if (out.tel && out.email && out.score >= 60 && out.contact) break;
    if (lues >= 6) break;
    if (!urlSure(u)) continue;
    const stop = new AbortController();
    const minuteur = setTimeout(() => stop.abort(), 8000);
    try {
      const r = await fetch(u, {
        headers: { "User-Agent": SIGNATURE, "Accept": "text/html" },
        signal: stop.signal, redirect: "follow",
      });
      if (!r.ok) continue;
      lues++;
      const html = (await r.text()).slice(0, 400000);
      if (!out.tel) out.tel = numeroDansTexte(html);
      const m = mailsDansTexte(html, domaine);
      if (m.score > out.score) { out.email = m.email; out.score = m.score; }
      if (!out.contact) out.contact = dirigeantDansTexte(html);
    } catch { /* injoignable ou trop lent : page suivante */ }
    finally { clearTimeout(minuteur); }
  }
  return out;
}

async function telSurSite(site: string): Promise<string> {
  let u = String(site ?? "").trim();
  if (!u) return "";
  if (!/^https?:\/\//i.test(u)) u = "https://" + u;
  if (!urlSure(u)) return "";
  return (await lireSite(u)).tel;
}

// ─── Retrouver le site d'une entreprise à partir de son nom ────────
// Le registre donne le nom et l'adresse, jamais le site ni le
// téléphone. Mais une entreprise qui a un site l'a presque toujours
// baptisé d'après son propre nom. On fabrique donc les adresses
// plausibles, on va voir si elles existent, et on ne retient une page
// que si elle parle bien de cette entreprise-là : son nom ou sa ville
// doit y figurer. Sans cette vérification, on ramènerait le numéro du
// premier squatteur de domaine venu.

const FORMES = /\b(sarl|sas|sasu|sa|eurl|selarl|selas|selafa|scp|sci|snc|sc|eirl|earl|scop|sem|gie|societe|société|cabinet)\b/gi;
const PETITS = /\b(et|de|du|des|la|le|les|aux|au|d|l|the|and)\b/gi;

function sansAccents(x: string): string {
  return x.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
}

function motsDuNom(nom: string): string[] {
  return sansAccents(String(nom ?? "").toLowerCase())
    .replace(FORMES, " ")
    .replace(PETITS, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim().split(/\s+/).filter((m) => m.length > 1);
}

function domainesPossibles(nom: string): string[] {
  const m = motsDuNom(nom);
  if (!m.length) return [];
  const bases = new Set<string>();
  const deux = m.slice(0, 2);
  const trois = m.slice(0, 3);
  bases.add(trois.join("-"));
  bases.add(trois.join(""));
  if (deux.length === 2) { bases.add(deux.join("-")); bases.add(deux.join("")); }
  // Un seul mot ne vaut que s'il est assez long pour être un nom
  // propre : « pro.fr » appartient à quelqu'un d'autre.
  if (m[0].length >= 6) bases.add(m[0]);

  const out: string[] = [];
  for (const b of bases) {
    if (b.length < 4 || b.length > 40) continue;
    out.push(`https://www.${b}.fr`);
    out.push(`https://${b}.fr`);
    out.push(`https://www.${b}.com`);
  }
  return out.slice(0, 9);
}

// La page parle-t-elle bien de cette entreprise ? On exige la ville,
// ou deux mots du nom, ou le SIREN. Une seule coïncidence de mot ne
// suffit pas.
function laBonnePage(html: string, nom: string, ville: string, siren: string): boolean {
  const t = sansAccents(html.toLowerCase());
  if (siren && t.includes(siren)) return true;
  const v = sansAccents(String(ville ?? "").toLowerCase()).replace(/[^a-z]+/g, " ").trim();
  if (v.length > 3 && t.includes(v)) return true;
  const m = motsDuNom(nom).filter((x) => x.length > 3);
  let n = 0;
  for (const x of m) if (t.includes(x)) n++;
  return n >= 2;
}

async function pageDe(u: string): Promise<string> {
  if (!urlSure(u)) return "";
  const stop = new AbortController();
  const minuteur = setTimeout(() => stop.abort(), 6000);
  try {
    const r = await fetch(u, {
      headers: { "User-Agent": SIGNATURE, "Accept": "text/html" },
      signal: stop.signal, redirect: "follow",
    });
    if (!r.ok) return "";
    const ct = r.headers.get("content-type") ?? "";
    if (!/html/i.test(ct)) return "";
    return (await r.text()).slice(0, 300000);
  } catch { return ""; }
  finally { clearTimeout(minuteur); }
}

async function siteEtTel(nom: string, ville: string, siren: string): Promise<Trouvaille & { site: string }> {
  for (const u of domainesPossibles(nom)) {
    const html = await pageDe(u);
    if (!html) continue;
    if (!laBonnePage(html, nom, ville, siren)) continue;
    // La page est la bonne : on lit tout le site, pas seulement l'accueil.
    const t = await lireSite(u);
    if (!t.tel) t.tel = numeroDansTexte(html);
    return { site: u, tel: t.tel, email: t.email, score: t.score, contact: t.contact };
  }
  return { site: "", tel: "", email: "", score: -1, contact: "" };
}

// Ce qu'on écrit sur la fiche à partir d'une lecture. Jamais par-dessus
// ce que quelqu'un a saisi à la main : une adresse obtenue au téléphone
// vaut plus que n'importe quelle page.
function champsDepuis(p: Record<string, string>, t: Trouvaille, site?: string) {
  // Deux mémoires distinctes : « j'ai cherché un numéro » et « j'ai
  // cherché une adresse ». Les confondre condamnait une fiche visitée
  // pour son téléphone à ne jamais être revisitée pour son e-mail.
  const maj: Record<string, unknown> = {
    site_lu_le: new Date().toISOString(),
    tel_cherche_le: new Date().toISOString(),
    mail_cherche_le: new Date().toISOString(),
  };
  if (site && !p.site) maj.site = site;
  if (!p.tel && t.tel) maj.tel = t.tel;
  if (!p.email && t.email) {
    maj.email = t.email;
    maj.email_origine = t.score >= 90 ? "direction" : t.score >= 60 ? "personne" : "generique";
  }
  if (!p.contact && t.contact) maj.contact = t.contact;
  return maj;
}

// ─── La porte ──────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  // Seule l'équipe entre. Et c'est le jeton qui dit qui, pas le corps :
  // « par » n'est plus lu, on ne signe qu'en son propre nom.
  const jeton = jetonDe(req);
  if (!(await estStaff(jeton))) return repondre({ erreur: "Accès refusé." }, 403);
  const moi = emailDuJeton(jeton);

  let corps: Record<string, string>;
  try { corps = await req.json(); } catch { return repondre({ erreur: "Corps illisible" }, 400); }

  try {
    if (corps.action === "chercher") {
      const activite = corps.activite === "tiimizy" ? "tiimizy" : "bornistes";
      const naf = String(corps.naf ?? "").toUpperCase().replace(/[^0-9A-Z]/g, "");
      const dep = String(corps.departement ?? "").trim().toUpperCase();
      // annuaire = OpenStreetMap, des fiches avec numéro tout de suite.
      // registre = l'État, exhaustif mais sans aucun téléphone.
      const source = corps.source === "registre" ? "registre" : "annuaire";
      if (!naf) return repondre({ erreur: "Code d’activité manquant." }, 400);
      if (!/^(0?[1-9]|[1-8][0-9]|9[0-5]|2[AB]|97[1-6])$/.test(dep))
        return repondre({ erreur: "Département invalide. Deux chiffres, ou 2A, 2B, ou 971 à 976." }, 400);

      const cible = (await lire("ls_cibles",
        `select=id,nom,osm&activite=eq.${activite}&naf=eq.${naf}&limit=1`))[0] as Record<string, string> | undefined;

      // La page de départ vient de l'appelant : le registre a bien plus
      // que ce qu'une seule invocation peut avaler, alors on avance par
      // tranches et on lui rend la page suivante.
      const depart = Math.max(1, Number(corps.page ?? 1));
      let suivante: number | null = null;
      let trouves: Fiche[];
      if (source === "annuaire") trouves = await interrogerAnnuaire(cible?.osm ?? "", dep);
      else {
        const r = await interrogerRegistre(naf, dep, depart);
        trouves = r.fiches; suivante = r.suivante;
      }

      // On ne réécrit jamais une fiche existante : elle peut déjà
      // porter un contrat, un historique d'appels, un compte.
      const deja = new Set<string>();
      const dejaTel = new Set<string>();
      const avecSiren = trouves.filter((f) => f.siren);
      for (let i = 0; i < avecSiren.length; i += 200) {
        const lot = avecSiren.slice(i, i + 200).map((f) => f.siren);
        const l = await lire("ls_prescripteurs",
          `select=siren&activite=eq.${activite}&siren=in.(${lot.join(",")})`);
        for (const x of l) deja.add(String((x as Record<string, string>).siren));
      }
      if (source === "annuaire") {
        const l = await lire("ls_prescripteurs",
          `select=tel&activite=eq.${activite}&tel=neq.&limit=5000`);
        for (const x of l) dejaTel.add(telFr(String((x as Record<string, string>).tel)));
      }

      const neufs = trouves
        .filter((f) => (f.siren ? !deja.has(f.siren) : true))
        .filter((f) => (f.tel ? !dejaTel.has(f.tel) : true))
        .map((f) => ({
          // Le catalogue fait foi quand il connaît ce code : deux noms
          // pour un même NAF donneraient deux fichiers qu'on ne
          // retrouverait plus. Un code inconnu prend le libellé donné.
          nom: f.nom, activite, type: cible?.nom ?? String(corps.metier ?? ""), statut: "A contacter",
          contact: f.contact, siren: f.siren || null, naf: f.naf,
          adresse: f.adresse, code_postal: f.code_postal, ville: f.ville,
          effectif: f.effectif, tel: f.tel ?? "", email: f.email ?? "", site: f.site ?? "",
          source, cible_id: cible?.id ?? null,
          owner_email: moi,
        }));

      const avant = await compter("ls_prescripteurs", `activite=eq.${activite}`);
      const pose = await insererFiches(neufs);
      const apres = await compter("ls_prescripteurs", `activite=eq.${activite}`);
      // On croit la base, pas la réponse d'insertion : c'est l'écart
      // entre avant et après qui dit ce qui existe vraiment.
      const crees = Math.max(pose.crees, apres - avant);

      await ecrire("ls_recherches", [{
        activite, cible_id: cible?.id ?? null, naf, departement: dep,
        trouves: trouves.length, crees, par: moi,
      }]);
      if (cible?.id)
        await majr("ls_cibles", `id=eq.${cible.id}`,
          { trouves: trouves.length, dernier_le: new Date().toISOString() });

      return repondre({
        trouves: trouves.length, crees, deja: trouves.length - neufs.length,
        avec_tel: neufs.filter((f) => f.tel).length, source,
        page: depart, page_suivante: suivante,
        refus: pose.refus,
      });
    }

    if (corps.action === "numero") {
      const id = String(corps.id ?? "");
      if (!id) return repondre({ erreur: "Fiche manquante." }, 400);
      const p = (await lire("ls_prescripteurs",
        `select=id,nom,adresse,code_postal,ville,tel&id=eq.${id}&limit=1`))[0] as Record<string, string>;
      if (!p) return repondre({ erreur: "Fiche introuvable." }, 404);
      if (p.tel) return repondre({ tel: p.tel, deja: true });

      const ou = [p.adresse, p.code_postal, p.ville].filter(Boolean).join(" ");
      const t = await chercherNumero(p.nom, ou, String(p.ville ?? ""));
      await majr("ls_prescripteurs", `id=eq.${id}`,
        { tel: t.tel, site: t.site, tel_cherche_le: new Date().toISOString() });
      return repondre({ tel: t.tel, deja: false });
    }

    // ─── Le numéro lu sur le site de l'entreprise ──────────────────
    // Gratuit, sans limite, sans clé. Une entreprise qui publie un site
    // y écrit son numéro : c'est même la raison d'être de la page
    // « contact ». On lit la page d'accueil, puis la page contact si
    // l'accueil ne dit rien.
    if (corps.action === "tel_depuis_site") {
      const activite = corps.activite === "tiimizy" ? "tiimizy" : "bornistes";
      const limite = Math.min(150, Math.max(1, Number(corps.limite ?? 40)));

      // Les fiches qui ont un site et à qui il manque encore quelque
      // chose. Une campagne cherche des adresses, une session d'appels
      // cherche des numéros : le manque n'est pas le même.
      const viseMail = corps.viser === "email";
      const manque = viseMail ? "&email=eq." : "&or=(tel.eq.,email.eq.)";
      const l = await lire("ls_prescripteurs",
        `select=id,nom,site,tel,email,contact&activite=eq.${activite}&site=neq.`
        + `&site_lu_le=is.null${manque}&order=cree_le.desc&limit=${limite}`) as Record<string, string>[];

      let trouves = 0, mails = 0, sans = 0;
      const debut = Date.now();
      // Douze sites de front plutôt que quatre : ce sont des attentes
      // réseau, pas du calcul, et quatre mille fiches à quatre par
      // paquet, c'est une journée. Les serveurs visités sont tous
      // différents, on ne charge personne.
      for (let i = 0; i < l.length; i += 12) {
        if (Date.now() - debut > 100000) break;
        await Promise.all(l.slice(i, i + 12).map(async (p) => {
          const t = await lireSite(p.site);
          await majr("ls_prescripteurs", `id=eq.${p.id}`, champsDepuis(p, t));
          if (!p.tel && t.tel) trouves++;
          if (!p.email && t.email) mails++;
          if (!t.tel && !t.email) sans++;
        }));
      }
      const restants = await compter("ls_prescripteurs",
        `activite=eq.${activite}&site=neq.&site_lu_le=is.null${manque}`);
      return repondre({ traites: l.length, trouves, mails, sans, restants });
    }

    // Retrouver le site puis le numéro, à partir du seul nom. C'est ce
    // qui rend le registre exploitable : il donne des milliers de noms,
    // et cette passe les transforme en fiches appelables sans un
    // centime ni la moindre clé.
    if (corps.action === "tel_par_domaine") {
      const activite = corps.activite === "tiimizy" ? "tiimizy" : "bornistes";
      const limite = Math.min(150, Math.max(1, Number(corps.limite ?? 30)));

      const viseMail2 = corps.viser === "email";
      const memoire = viseMail2 ? "mail_cherche_le=is.null" : "tel_cherche_le=is.null";
      const l = await lire("ls_prescripteurs",
        `select=id,nom,ville,siren,tel,email,contact,site&activite=eq.${activite}`
        + `&${viseMail2 ? "email=eq." : "tel=eq."}&site=eq.`
        + `&${memoire}&order=cree_le.desc&limit=${limite}`) as Record<string, string>[];

      let trouves = 0, sans = 0, mails = 0;
      const debut = Date.now();
      // Chaque fiche demande plusieurs essais de domaine : c'est la
      // passe la plus lente, et celle qui produit le plus. Douze de
      // front au lieu de six.
      for (let i = 0; i < l.length; i += 12) {
        if (Date.now() - debut > 95000) break;
        await Promise.all(l.slice(i, i + 12).map(async (p) => {
          const r = await siteEtTel(p.nom, String(p.ville ?? ""), String(p.siren ?? ""));
          const maj = champsDepuis(p, r, r.site);
          if (!r.site) maj.site_lu_le = null;   // rien lu : ne pas prétendre l'inverse
          await majr("ls_prescripteurs", `id=eq.${p.id}`, maj);
          if (r.tel) trouves++; else sans++;
          if (r.email) mails++;
        }));
      }
      const restants = await compter("ls_prescripteurs",
        `activite=eq.${activite}&${viseMail2 ? "email=eq." : "tel=eq."}&site=eq.&${memoire}`);
      return repondre({ traites: trouves + sans, trouves, sans, mails, restants });
    }

    // Des milliers de fiches ne se traitent pas une par une depuis un
    // navigateur : trois mille allers-retours prendraient une heure et
    // mourraient au premier onglet fermé. On travaille par lots, cinq
    // requêtes de front, et on rend la main assez vite pour que la
    // fonction ne se fasse pas couper.
    if (corps.action === "numeros_lot") {
      if (!CLE_GOOGLE) return repondre({ erreur: "Aucune clé Google n’est posée dans les secrets du projet." }, 400);
      const activite = corps.activite === "tiimizy" ? "tiimizy" : "bornistes";
      const limite = Math.min(120, Math.max(1, Number(corps.limite ?? 60)));

      const l = await lire("ls_prescripteurs",
        `select=id,nom,adresse,code_postal,ville&activite=eq.${activite}`
        + `&tel=eq.&tel_cherche_le=is.null&order=cree_le.desc&limit=${limite}`) as Record<string, string>[];

      let trouves = 0, sans = 0, erreur = "";
      const debut = Date.now();
      for (let i = 0; i < l.length; i += 5) {
        if (Date.now() - debut > 100000) break;   // on rend la main avant d'être coupé
        await Promise.all(l.slice(i, i + 5).map(async (p) => {
          try {
            const ou = [p.adresse, p.code_postal, p.ville].filter(Boolean).join(" ");
            const t = await chercherNumero(p.nom, ou, String(p.ville ?? ""));
            await majr("ls_prescripteurs", `id=eq.${p.id}`,
              { tel: t.tel, site: t.site, tel_cherche_le: new Date().toISOString() });
            if (t.tel) trouves++; else sans++;
          } catch (e) {
            if (!erreur) erreur = String((e as Error).message ?? e).slice(0, 200);
          }
        }));
        if (erreur) break;
      }

      const restants = await compter("ls_prescripteurs",
        `activite=eq.${activite}&tel=eq.&tel_cherche_le=is.null`);
      return repondre({ traites: trouves + sans, trouves, sans, restants, erreur });
    }

    return repondre({ erreur: "Action inconnue." }, 400);
  } catch (e) {
    return repondre({ erreur: String((e as Error).message ?? e).slice(0, 400) }, 500);
  }
});
