local claims = {
  email_verified: false,
} + std.extVar('claims');

{
  identity: {
    traits: {
      email: claims.email,
      [if 'given_name' in claims then 'name' else null]: claims.given_name + (if 'family_name' in claims then ' ' + claims.family_name else ''),
      [if 'picture' in claims then 'picture' else null]: claims.picture,
    },
  },
}
