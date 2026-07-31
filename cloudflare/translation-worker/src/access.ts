import { createRemoteJWKSet, jwtVerify } from "jose";

export interface AdminIdentity {
  email: string;
}

export type AdminAuthentication =
  | { identity: AdminIdentity; response?: never }
  | { identity?: never; response: Response };

interface AccessEnv {
  ADMIN_API_ENABLED: string;
  ADMIN_DEV_EMAIL: string;
  TEAM_DOMAIN: string;
  POLICY_AUD: string;
}

function json(value: unknown, status: number): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function validatedTeamDomain(value: string): string | null {
  try {
    const url = new URL(value);
    if (
      url.protocol !== "https:" ||
      !url.hostname.endsWith(".cloudflareaccess.com") ||
      url.pathname !== "/" ||
      url.search ||
      url.hash
    ) {
      return null;
    }
    return url.origin;
  } catch {
    return null;
  }
}

export async function authenticateAdminRequest(
  request: Request,
  env: AccessEnv,
): Promise<AdminAuthentication> {
  if (String(env.ADMIN_API_ENABLED) !== "true") {
    return { response: json({ error: "Not found." }, 404) };
  }

  const requestHostname = new URL(request.url).hostname;
  const developmentEmail = String(env.ADMIN_DEV_EMAIL)
    .trim()
    .toLocaleLowerCase("en-US");
  if (
    (requestHostname === "localhost" || requestHostname === "127.0.0.1") &&
    developmentEmail &&
    developmentEmail.length <= 320
  ) {
    return { identity: { email: developmentEmail } };
  }

  const teamDomain = validatedTeamDomain(String(env.TEAM_DOMAIN).trim());
  const audience = String(env.POLICY_AUD).trim();
  if (!teamDomain || !audience || audience.length > 512) {
    console.error(
      JSON.stringify({
        message: "Admin API enabled without valid Cloudflare Access configuration.",
      }),
    );
    return {
      response: json(
        { error: "Administration authentication is not configured." },
        503,
      ),
    };
  }

  const token = request.headers.get("cf-access-jwt-assertion");
  if (!token || token.length > 16_384) {
    return {
      response: json({ error: "Cloudflare Access authentication is required." }, 401),
    };
  }

  try {
    const jwks = createRemoteJWKSet(
      new URL(`${teamDomain}/cdn-cgi/access/certs`),
    );
    const { payload } = await jwtVerify(token, jwks, {
      algorithms: ["RS256"],
      issuer: teamDomain,
      audience,
    });
    const email =
      typeof payload.email === "string"
        ? payload.email.trim().toLocaleLowerCase("en-US")
        : "";
    if (!email || email.length > 320) {
      return {
        response: json(
          { error: "The Access identity does not include a valid email." },
          403,
        ),
      };
    }
    return { identity: { email } };
  } catch (error) {
    console.warn(
      JSON.stringify({
        message: "Cloudflare Access JWT validation failed.",
        error: error instanceof Error ? error.message : String(error),
      }),
    );
    return {
      response: json({ error: "Cloudflare Access authentication is invalid." }, 401),
    };
  }
}

export { validatedTeamDomain };
