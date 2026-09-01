from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as fh:
    long_description = fh.read()

setup(
    name="lingofuse",
    version="1.0.0",
    author="passbyyou888 / Team",
    author_email="600585@qq.com",
    description="Python bindings for the LingoFuse RPC framework",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/PassByYou888/LingoFuse",
    packages=find_packages(exclude=["cross", "cross.*", "tests", "*.tests"]),
    include_package_data=True,
    python_requires=">=3.7",
    install_requires=[],
    extras_require={
        "bridge": [
            "Flask>=2.0",
            "requests>=2.25",
        ],
        "dev": [
            "pytest>=7.0",
            "black",
            "flake8",
        ],
    },
    entry_points={
        "console_scripts": [
            "lingofuse-bridge = lingofuse.bridge:main",
        ],
    },
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],
)