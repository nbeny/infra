#!/usr/bin/env python3
"""Confronte les expressions ajoutees a Fail2ban a de vraies lignes de journal.

Deux choses sont verifiees, et la seconde est celle qui compte :

  1. chaque ligne d'attaque est bien reconnue par au moins une expression ;
  2. `group(1)` -- ce que lit exactement le conteneur netfilter de Mailcow,
     dans data/Dockerfiles/netfilter/main.py:271 -- est bien l'adresse IP.

Le point 2 attrape une classe de bogue silencieuse : une expression avec un
groupe capturant parasite en tete est acceptee sans broncher par l'API, puis
fait bannir une chaine de caracteres au lieu d'une adresse.

Usage : tester-regex-f2b.py '["expression", ...]'
"""
import json
import re
import sys

# Lignes reelles, relevees dans le journal de Postfix le 2026-09-05, ou
# reconstituees a l'identique a partir du format que Postfix emet.
CAS = [
    # Rejet par postscreen : « RCPT from [IP]:port », sans nom d'hote.
    ("NOQUEUE: reject: RCPT from [136.64.100.47]:51720: 550 5.7.1 "
     "Service unavailable; client [136.64.100.47] blocked using "
     "zen.spamhaus.org; from=<a@b.tld>, to=<c@urbanlink.fr>",
     "136.64.100.47"),
    # Rejet par smtpd : « RCPT from hote[IP]:port ». C'est le second format,
    # celui que l'expression doit couvrir aussi.
    ("NOQUEUE: reject: RCPT from relais.exemple.net[203.0.113.9]:2525: "
     "550 5.1.1 <x@urbanlink.fr>: Recipient address rejected: User unknown",
     "203.0.113.9"),
    ("postfix/postscreen[2822]: PREGREET 11 after 0.05 "
     "from [198.51.100.4]:41234: EHLO x", "198.51.100.4"),
    ("postfix/postscreen[2822]: COMMAND TIME LIMIT "
     "from [198.51.100.5]:41235", "198.51.100.5"),
    ("postfix/postscreen[2822]: COMMAND COUNT LIMIT "
     "from [198.51.100.6]:41236", "198.51.100.6"),
]

# Lignes qui ne doivent SURTOUT PAS declencher un bannissement.
CAS_NEGATIFS = [
    # Une remise reussie.
    "postfix/smtpd[123]: connect from mail-ed1-f42.google.com[209.85.208.42]",
    # Un differe temporaire du greylisting : l'expediteur est legitime et
    # retentera. Le bannir couperait le courrier.
    ("NOQUEUE: reject: RCPT from mail.exemple.net[203.0.113.20]:33333: "
     "450 4.7.1 <x@urbanlink.fr>: Recipient address rejected: "
     "Greylisted, please try again later"),
]


def main():
    if len(sys.argv) < 2:
        print("usage : tester-regex-f2b.py '[\"expression\", ...]'")
        return 2
    expressions = json.loads(sys.argv[1])

    echecs = []

    for ligne, attendu in CAS:
        trouve = None
        for exp in expressions:
            m = re.search(exp, ligne)
            if m:
                trouve = m.group(1)
                break
        if trouve != attendu:
            echecs.append(
                "NON RECONNU ou mauvais groupe : %r\n"
                "    obtenu %r, attendu %r" % (ligne[:70], trouve, attendu))

    for ligne in CAS_NEGATIFS:
        for exp in expressions:
            if re.search(exp, ligne):
                echecs.append(
                    "FAUX POSITIF : %r\n    declenche par %r" % (ligne[:70], exp))

    if echecs:
        print("\n".join(echecs))
        return 1

    print("%d lignes d'attaque reconnues avec group(1) = adresse, "
          "%d lignes legitimes ignorees"
          % (len(CAS), len(CAS_NEGATIFS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
