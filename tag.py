import datetime
import subprocess

components = [
    "omnilife-tonguecapture-dummy",
    "reportautomationbackend-dummy",
    "theomnilifecoreapi-dummy",
    "theomnilife-frontend-dummy",
    "activity-dashboard"
]

repository_prefix = "878239241975.dkr.ecr.us-east-2.amazonaws.com/"
timestamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")

for component in components:
    source_tag = f"{repository_prefix}{component}:latest"
    target_tag = f"{repository_prefix}{component}:{timestamp}"

    result = subprocess.run(["docker", "image", "inspect", source_tag],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)

    if result.returncode == 0:
        subprocess.run(["docker", "tag", source_tag, target_tag], check=True)
        print(f"✅ Tagged {source_tag} → {target_tag}")

        image_list = subprocess.check_output(
            ["docker", "images", f"{repository_prefix}{component}", "--format", "{{.Repository}}:{{.Tag}} {{.CreatedAt}}"]
        ).decode().splitlines()

        timestamped_tags = [
            line.split()[0]
            for line in image_list
            if not line.startswith(f"{repository_prefix}{component}:latest")
        ]

        timestamped_tags.sort(reverse=True)

        for old_tag in timestamped_tags[6:]:
            subprocess.run(["docker", "rmi", old_tag], check=True)
            print(f"🧹 Removed old image: {old_tag}")
    else:
        print(f"⏭️ Image not found: {source_tag}, skipping.")
