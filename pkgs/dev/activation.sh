mkdir -p /home/vmuser/.ssh
cp /etc/ssh/id_ed25519 /home/vmuser/.ssh/id_ed25519
chown vmuser:users /home/vmuser/.ssh/id_ed25519
chmod 600 /home/vmuser/.ssh/id_ed25519
echo "@devPublicKey@" > /home/vmuser/.ssh/id_ed25519.pub
chown vmuser:users /home/vmuser/.ssh/id_ed25519.pub
