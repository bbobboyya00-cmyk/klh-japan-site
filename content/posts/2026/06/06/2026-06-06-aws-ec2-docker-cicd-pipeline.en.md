---
title: "Provisioning AWS Infrastructure and Implementing a Docker-based CI/CD Pipeline"
slug: "aws-ec2-docker-cicd-pipeline"
date: 2026-06-06T10:13:39+09:00
draft: false
image: ""
description: "Detailed explanation of building a payment infrastructure using AWS EC2 (ARM64) and RDS, and the automation process of Docker deployment via GitHub Actions. A practical implementation record including Spring Cloud AWS dependency conflict resolution and the transition of HTTPS configurations."
categories: ["Linux System Admin"]
tags: ["aws-ec2", "docker-container", "github-actions", "amazon-corretto", "spring-boot"]
author: "K-Life Hack"
---

This article describes the migration process from manual AWS infrastructure construction to a fully automated CI/CD pipeline using Docker and GitHub Actions for the deployment of a commerce payment application. It covers network environment configuration, the transition of HTTPS implementation, dependency conflict resolution within the Spring Boot ecosystem, and implementation details of cloud deployment via containerization.



## 1. AWS Infrastructure Configuration

### 1.1 Network Architecture
The underlying infrastructure was built within a custom Virtual Private Cloud (VPC). For the purpose of resource isolation, public and private subnets were implemented, and an Internet Gateway (IGW) and route tables were configured to control traffic flow.



### 1.2 Compute Layer (EC2)
The application runs on an Amazon EC2 <b>t4g.small</b> instance employing ARM architecture, considering cost efficiency and performance. Amazon Corretto 17 (OpenJDK 17.0.19) was adopted as the runtime.



```bash
sudo dnf install java-17-amazon-corretto -y
java -version
# Output: openjdk version "17.0.19" 2026-04-21 LTS
```

### 1.3 Database Layer (RDS)
A managed MySQL instance was provisioned for persistent data management.



* <b>Engine:</b> MySQL 8.0.43
* <b>Instance Class:</b> db.t4g.micro
* <b>Provisioning Script:</b>

```bash
aws rds create-db-instance \
  --db-instance-identifier commerce-db \
  --db-instance-class db.t4g.micro \
  --engine mysql \
  --engine-version 8.0.43 \
  --master-username admin \
  --master-user-password [PASSWORD_REDACTED] \
  --allocated-storage 20 \
  --db-subnet-group-name commerce-subnet-group \
  --publicly-accessible \
  --region ap-northeast-2
```

## 2. HTTPS Configuration and Domain Management

### 2.1 Initial Implementation: Caddy &amp; nip.io
During the prototyping stage, HTTPS was implemented by combining Caddy, which features automatic TLS, with the nip.io wildcard DNS service. To support the ARM64 environment, a method of directly obtaining the binary was used.



```bash
curl -L "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_arm64.tar.gz" -o caddy.tar.gz
tar -xzf caddy.tar.gz
sudo mv caddy /usr/local/bin/
```

### 2.2 Production Environment Implementation: ACM &amp; ALB
With the migration to the production environment, the configuration was upgraded to use AWS Certificate Manager (ACM) and Application Load Balancer (ALB). Domain management is handled by Route 53, and the structure terminates HTTPS traffic at the ALB and forwards it to the EC2 target group.



## 3. Spring Cloud AWS Compatibility Issues and Resolution

### 3.1 Analysis of Technical Conflicts
When the spring-cloud-aws dependency was introduced for the purpose of environment variable management via AWS Parameter Store, a serious compatibility issue occurred with Spring Boot 4.x.



* <b>Error Log:</b>
```text
java.lang.NoSuchMethodError: 'org.springframework.boot.ConfigurableBootstrapContext 
org.springframework.boot.context.config.ConfigDataLocationResolverContext.getBootstrapContext()'
```

### 3.2 Implementation of Workaround
Since the NoSuchMethodError was not resolved even after updating the dependency version from 3.1.1 to 3.3.0, the dependency was removed, and the strategy was switched to directly injecting environment variables during JAR execution.



```bash
nohup java -jar commerce-payment-application-0.0.1-SNAPSHOT.jar \
  --spring.profiles.active=prod \
  --PROD_DB_URL=jdbc:mysql://[RDS_ENDPOINT]:3306/commerce_db \
  --PROD_DB_USERNAME=admin \
  --PROD_DB_PASSWORD=[PASSWORD_REDACTED] \
  --PROD_JWT_SECRET=[SECRET_KEY_REDACTED] &gt; ~/app.log 2&gt;&amp;1 &amp;
```

## 4. Docker CI/CD Pipeline Construction

### 4.1 Containerization (Dockerfile)
Created a container image optimized for the AWS environment using Amazon Corretto 17 as the base image.



```dockerfile
FROM amazoncorretto:17
WORKDIR /app
COPY commerce-payment-application-0.0.1-SNAPSHOT.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 4.2 Automated Workflow via GitHub Actions
A pipeline was constructed to automate the build, push to Docker Hub, and deployment to EC2, triggered by a push to the dev branch.



```yaml
name: Deploy to EC2
on:
  push:
    branches: [ dev ]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      - name: Set up JDK 17
        uses: actions/setup-java@v3
        with:
          java-version: '17'
          distribution: 'corretto'
      - name: Build with Gradle
        run: ./gradlew build -x test
      - name: Docker Build &amp; Push
        run: |
          docker build -t ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest .
          docker push ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest
      - name: Deploy on EC2
        uses: appleboy/ssh-action@master
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ec2-user
          key: ${{ secrets.EC2_KEY }}
          script: |
            docker pull ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest
            docker stop commerce-app || true
            docker rm commerce-app || true
            docker run -d --name commerce-app --restart=always -p 8080:8080 \
              -e SPRING_PROFILES_ACTIVE=prod \
              -e PROD_DB_URL=${{ secrets.PROD_DB_URL }} \
              -e PROD_DB_USERNAME=${{ secrets.PROD_DB_USERNAME }} \
              -e PROD_DB_PASSWORD=${{ secrets.PROD_DB_PASSWORD }} \
              -e PROD_JWT_SECRET=${{ secrets.PROD_JWT_SECRET }} \
              ${{ secrets.DOCKER_USERNAME }}/commerce-payment:latest
```

## 5. Troubleshooting Logs

| Event | Cause | Solution |
| :--- | :--- | :--- |
| Spring Cloud AWS Conflict | Lack of compatibility with Spring Boot 4.x | Removed dependency and adopted direct injection of environment variables |
| RDS Connection Failure | Typo in endpoint | Corrected DNS endpoint string |
| Hibernate Table Error | ddl-auto: validate failure | Applied ddl-auto: create on first startup |
| Caddy Installation Failure | ARM architecture mismatch | Explicitly downloaded binary for arm64 |
| Docker Permission Error | Insufficient access rights to the daemon | Executed with sudo or adjusted user groups |

## Lessons Learned
Through this project, the importance of environment configuration separation and security was reaffirmed. Exposure to source code is prevented by excluding application-local.yaml via .gitignore and managing sensitive information with GitHub Secrets. Furthermore, in infrastructure construction, provisioning RDS before EC2 and strictly controlling security groups within the same VPC are key to building a stable cloud architecture.

