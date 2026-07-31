# Estado local a propósito: bootstrap crea el backend remoto que el resto de
# la plataforma va a usar, así que no puede depender de él (dependencia circular).
# El archivo terraform.tfstate resultante debe resguardarse fuera del repo
# (por ejemplo, cifrado en un gestor de secretos) tras cada apply.
