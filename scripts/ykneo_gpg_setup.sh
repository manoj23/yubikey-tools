#!/bin/bash

# Bash script's path
script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE:-$0}")" && printf '%s\n' "$(pwd -P)")

# Backup files will be exported to this directory
key_dir=${script_dir}/export

# Directory where the GnuPG keyring will be created
keyring_dir=${script_dir}/keyring


#
# Configuration
#

# Default Admin and User PINs
default_admin_pin="12345678"
default_user_pin="123456"

# Identity
fullname="John Doe"
surname=${fullname#* }
given_name=${fullname% *}
email="john@john.doe"

# Master and sub-keys
masterkey_size="4096"
masterkey_expire="2y"
subkey_size="2048"
subkey_expire="1y"

# Revocation certificate
revoke_reason="1"
revoke_comment=""

# Passphrases and PINs
passphrase=""
admin_pin=""
user_pin=""
reset_code=""

# Yubikey configuration
lang="en"
sex="M"
login="jdoe"
public_key_url="http://john.doe/publickey.asc"
pin_retries=5

# LUKS container
luks_passphrase=""


#
# Functions
#

# Reset the Yubikey OpenPGP applet
# WARNING: This will reset the PIN codes!
function yubikey_reset_pgp_applet() {

    # We provide a wrong user and then admin PIN to the verify mechanism to lock the key,
    # then we send the command to terminate and reset the applet.
    gpg-connect-agent --hex \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 e6 00 00" \
        "scd apdu 00 44 00 00" \
    /bye
}

# Set the Yubikey's PIN retries counter
function yubikey_set_pgp_retries() {

    local pin_cmd
    local pin=$1

    # Format the PIN for the APDU command
    for ((i=0; i<8; i++)); do
        pin_cmd="${pin_cmd} 3${pin:$i:1}"
    done

    # We start by verifying the admin PIN and then sending the command
    # to set the pin retry counter for the User, Admin and Reset PIN.
    gpg-connect-agent --hex \
        "scd apdu 00 20 00 83 ${pin_cmd}" \
        "scd apdu 00 f2 00 00 03 0${pin_retries} 0${pin_retries} 0${pin_retries}" \
        /bye
}

# Prepare the GnuPG agent
function gpg_setup_keyring() {

    # Generate enough entropy for keys generation
    sudo rngd -r /dev/urandom

    # Kill all the 'gpg-agent' daemons
    killall gpg-agent

    # Store the GnuPG keyring into the following folder
    export GNUPGHOME=${keyring_dir}

    # Erase previous instance of the keyring
    rm -Rf $GNUPGHOME

    # Create the keyring directory
    mkdir -p $GNUPGHOME

    # Copy the GnuPG configuration
    cp ${script_dir}/conf/gpg.conf $GNUPGHOME

    # Copy the GnuPG agent configuration
    cp ${script_dir}/conf/gpg-agent.conf $GNUPGHOME
}

# Generate a GnuPG keyring with master and sub-keys
function gpg_gen_keys() {

    # Generate the master key
    gpg2 --full-gen-key \
        --no-tty --command-fd 0 --status-fd 1 \
        --pinentry-mode loopback \
<<-EOF
4
${masterkey_size}
${masterkey_expire}
${fullname}
${email}

${passphrase}
EOF


    # Generate the subkeys
    gpg2 --expert \
        --no-tty --command-fd 0 --status-fd 1 \
        --pinentry-mode loopback \
        --edit-key ${email} \
<<-EOF
addkey
4
${subkey_size}
${subkey_expire}
${passphrase}
${passphrase}
addkey
6
${subkey_size}
${subkey_expire}
${passphrase}
addkey
8
S
E
A
Q
${subkey_size}
${subkey_expire}
${passphrase}
save
EOF

}

# Export the GnuPG keyring files
function gpg_backup_keys() {

    local key_id=$(gpg2 --with-colons --list-key ${email} | grep pub | cut -d':' -f5)
    local key_fname=${key_dir}/${key_id}

    # Create the backup directory
    mkdir -p ${key_dir}

    # Export the secret keys
    printf ${passphrase} | gpg2 --pinentry-mode loopback --passphrase-fd 0 \
        --armor --export-secret-keys ${email} > ${key_fname}-secret-gpg.asc
    printf ${passphrase} | gpg2 --pinentry-mode loopback --passphrase-fd 0 \
        --no-armor --export-secret-keys ${email} > ${key_fname}-secret-gpg.key

    # Export the secret subkeys
    printf ${passphrase} | gpg2 --pinentry-mode loopback --passphrase-fd 0 \
        --armor --export-secret-subkeys ${email} > ${key_fname}-secret-sub-gpg.asc
    printf ${passphrase} | gpg2 --pinentry-mode loopback --passphrase-fd 0 \
        --no-armor --export-secret-subkeys ${email} > ${key_fname}-secret-sub-gpg.key

    # Export the public key
    gpg2 --armor --export ${email} > ${key_fname}-public-gpg.asc
    gpg2 --no-armor --export ${email} > ${key_fname}-public-gpg.key

    # Export the trust database
    gpg2 --export-ownertrust > ${key_fname}-ownertrust-gpg.txt

    # Generate a revocation certificate for the master key
    cat << EOF | gpg2 --pinentry-mode loopback --command-fd 0 \
        --gen-revoke ${email} > ${key_fname}-revocation-certificate.asc
y
${revoke_reason}
${revoke_comment}
y
${passphrase}
EOF

}

# Export the ssh key
function gpg_backup_ssh_key() {

    local key_id=$(gpg2 --with-colons --list-key ${email} | grep pub | cut -d':' -f5)
    local key_fname=${key_dir}/${key_id}

    # Use the ssh-agent spwaned by GnuPG
    export SSH_AUTH_SOCK=${keyring_dir}/S.gpg-agent.ssh

    # Retrive the ssh key
    ssh-add -L > ${key_fname}-card-ssh-key.pub
}

# Import GnuPG subkeys on the Yubikey
function yubikey_import_pgp_keys() {

    # Send the subkeys to the Yubikey
    gpg2 --expert \
        --no-tty --command-fd 0 --status-fd 1 \
        --pinentry-mode loopback \
        --edit-key ${email} \
<<-EOF
toggle
key 1
keytocard
1
${passphrase}
${default_admin_pin}
key 1
key 2
keytocard
2
${passphrase}
key 2
key 3
keytocard
3
${passphrase}
EOF

}

# Configure the Yubikey OpenPGP applet
function yubikey_configure_pgp_applet() {

    # Setup the smartcard and set PIN codes
    gpg2 --expert \
        --no-tty --command-fd 0 --status-fd 1 \
        --pinentry-mode loopback \
        --card-edit \
<<-EOF
admin
passwd
1
${default_user_pin}
${user_pin}
${user_pin}
3
${default_admin_pin}
${admin_pin}
${admin_pin}
4
${admin_pin}
${reset_code}
${reset_code}
Q
name
${surname}
${given_name}
url
${public_key_url}
login
${login}
lang
${lang}
sex
${sex}
EOF

}

# Generate a PDF with the master key and a revocation certificate
function gpg_generate_backup_pdf() {

    local key_id=$(gpg2 --with-colons --list-key ${email} | grep pub | cut -d':' -f5)
    local key_fname=${key_dir}/${key_id}
    local key_list=$(gpg2 -K --with-fingerprint | tail -n +3 )

    local tmp_dir=$(mktemp -d /tmp/gpgXXXXXX)

    # Split the private key in four files and generate a QRCode for each file
    split ${key_fname}-secret-gpg.asc -n 4 -d -a 1 ${tmp_dir}/key
    for f in ${tmp_dir}/key*; do cat $f | qrencode -v 40 -o $f.png; shred -u $f; done

    # Generate a QRCode of the revocation certificate
    cat ${key_fname}-revocation-certificate.asc | qrencode -v 20 -o ${tmp_dir}/revoke.png

    # Generate a PDF with the QRCodes
    cat << EOF | pdflatex -output-directory ${tmp_dir}
\documentclass{article}

\usepackage{graphicx}
\usepackage{caption}
\usepackage{wrapfig}
\usepackage{tikz}
\usepackage{listings}
\usepackage[margin=1cm]{geometry}

\begin{document}

\begin{wrapfigure}{r}{5cm}
  \vspace{-0.75cm}
  \begin{center}
    \includegraphics[width=5cm]{${tmp_dir}/revoke.png}
  \end{center}
  \vspace{-0.7cm}
  \caption*{Revocation certificate}
\end{wrapfigure}

\section*{\huge GnuPG}
\begin{lstlisting}[basicstyle=\fontsize{8}{8}\selectfont\ttfamily]
${key_list}
\end{lstlisting}

\pagenumbering{gobble}

\vspace{2.5cm}

\begin{figure}[hb]
  \centering
  \foreach \x in {3,2,1,0}
  {
    \includegraphics[width=9cm]{${tmp_dir}/key\x.png}
  }
\end{figure}

\end{document}
EOF

    # Move the generated PDF to the export folder
    mv ${tmp_dir}/texput.pdf ${key_fname}-backup.pdf

    # Destroy the generated files
    find ${tmp_dir} -type f -exec shred -u {} \;
    rmdir ${tmp_dir}
}

# Re-generate the master key and the revocation certificate
# from the given PDF file
function gpg_restore_backup_pdf() {

    local tmp_file=$(mktemp /tmp/gpgXXXXXX)

    # Convert the PDF file to a PNG image
    convert -density 150 $0 -quality 100 ${tmp_file}

    # Extract
    gpg_extract_from_image ${tmp_file}

    # Destroy the temporary file
    shred -u ${tmp_file}
}

# Re-generate the master key and the revocation certificate
# from the given image file
function gpg_extract_from_image() {

    local tmp_dir=$(mktemp -d /tmp/gpgXXXXXX)

    # Decode the picture and write the keys to different files
    zbarimg -q $0 | \
    awk -v d=${tmp_dir} 'BEGIN{
        RS="QR-Code:"
    }
    {
        if ($0 ~ /\n$/)
            $0=substr($0, 0, length($0))
        if($0 ~ /PUBLIC/)
            printf $0 > "revoke.asc"
        else
            printf $0 > "private-key.asc"
    }'

    echo "Imported keys in ${tmp_dir}. Press any key to continue."
    echo "WARNING: This will delete the generated files."
    local l; read l

    # Destroy the generated files
    find ${tmp_dir} -type f -exec shred -u {} \;
    rmdir ${tmp_dir}
}

# Backup the GnuPG files in a secure container
function gpg_backup_to_luks() {

    local key_id=$(gpg2 --with-colons --list-key ${email} | grep pub | cut -d':' -f5)
    local name="${key_id}-vault.luks"
    local size=20
    local format_args="--cipher aes-xts-plain64 --key-size 512 --hash sha512"
    local tmp_mnt=$(mktemp -d /tmp/gpg_vaultXXXXXX)

    # Generate a file to hold the LUKS container
    dd if=/dev/zero bs=1M count=${size} of=${script_dir}/${name}

    # Setup the LUKS container
    printf "${luks_passphrase}" | sudo cryptsetup \
        --verbose --key-file - ${format_args} \
        luksFormat ${script_dir}/${name}

    # Open the container using the passphrase
    printf "${luks_passphrase}" | sudo cryptsetup \
        --verbose --key-file - \
        luksOpen ${script_dir}/${name} gpg_vault

    # Format the device to ext4
    sudo mkfs.ext4 /dev/mapper/gpg_vault

    # Mount it
    sudo mount /dev/mapper/gpg_vault ${tmp_mnt}

    # Copy the exported files from GnuPG
    sudo cp -R ${key_dir}/* ${tmp_mnt}

    # Copy a working GnuPG v2.1 keyring
    sudo mkdir ${tmp_mnt}/keyring/
    sudo cp -R ${keyring_dir}/{*.conf,openpgp-revocs.d,private-keys-v1.d,pubring.kbx*,trustdb.gpg} ${tmp_mnt}/keyring/

    # Create an archive of the keyring
    sudo tar -C ${tmp_mnt} -cvjf ${tmp_mnt}/keyring_$(date +%Y-%m-%d-%H%M%S).tar.bz2 ./keyring

    # Unmount it and close the container
    sudo umount ${tmp_mnt}
    sudo cryptsetup luksClose gpg_vault

    # Generate a MD5 sum of the container
    md5sum ${script_dir}/${name} > ${script_dir}/${name}.md5

    # Remove the temporary mount point
    rmdir ${tmp_mnt}
}


# WARNING: Please keep the call order, PIN requested are hard coded in the functions
#          and the PIN retries reset sequence should be called before setting new PINs.
function main() {
    REQUIRED_PROGRAMS="awk \
                       convert \
                       cryptsetup \
                       gpg-agent \
                       gpg-connect-agent \
                       gpg2 \
                       md5sum \
                       mkfs.ext4 \
                       qrencode \
                       rngd \
                       shred \
                       split \
                       ssh-add \
                       zbarimg"

    for prog in $REQUIRED_PROGRAMS; do
         if ! command -v $prog >/dev/null 2>&1; then
             echo "$prog is not installed, Bye!"
             exit 1
         fi
    done

    gpg_setup_keyring

    yubikey_reset_pgp_applet

    gpg_gen_keys
    gpg_backup_keys

    yubikey_import_pgp_keys
    yubikey_set_pgp_retries ${default_admin_pin}
    yubikey_configure_pgp_applet

    gpg_backup_ssh_key
    gpg_generate_backup_pdf
    gpg_backup_to_luks
}

main $@
