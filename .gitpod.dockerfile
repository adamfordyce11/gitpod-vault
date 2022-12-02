FROM gitpod/workspace-full

# Install QEMU
RUN sudo apt update -y; \
    sudo apt upgrade -y; \
    sudo apt update -y; \
    sudo apt install -y \
         qemu \
         qemu-system-x86 \
         linux-image-generic \
         libguestfs-tools \
         sshpass \
         netcat

# Install kubectl
RUN sudo apt install netcat sshpass -y \
    sudo curl -o /usr/bin/kubectl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    sudo chmod +x /usr/bin/kubectl

# Install Helm
RUN curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null \
    sudo apt-get install apt-transport-https --yes \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list \
    sudo apt-get update \
    sudo apt-get install helm