import datetime
import ipaddress
import os
from zoneinfo import ZoneInfo

from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.x509.oid import NameOID

__all__ = [
    'CertificateGenerator'
]


class CertificateGenerator:
    def __init__(self, cert_dir, subject_info):
        self.cert_dir = cert_dir
        self.subject_info = self.get_subject_info(subject_info)
        # secret_key 仅用于「客户端证书私钥」PEM 加密；未填则全部私钥明文
        _sk = self.subject_info.get('secret_key')
        _pem_pass = str(_sk).strip() if _sk is not None else ''
        self.generator = CertificateGeneratorHelper(
            cert_dir=self.cert_dir,
            client_key_passphrase=_pem_pass,
        )

        # 初始化证书对象
        self.root_private_key = None
        self.root_private_key_file = None
        self.root_cert = None
        self.intermediate_csr = None
        self.intermediate_private_key = None
        self.intermediate_private_key_file = None
        self.intermediate_cert = None
        self.intermediate_cert_file = None
        self.server_private_key = None
        self.server_csr = None
        self.server_cert = None
        self.server_cert_file = None
        self.client_private_key = None
        self.client_private_key_file = None
        self.client_csr = None
        self.client_cert = None
        self.client_cert_file = None
        self.root_cert_file = None

        # 获取 SAN 列表
        self.san_list = self.get_san_list()

        # 为不同的证书创建不同的主题信息
        self.root_subject_info = self._create_root_subject_info()
        self.intermediate_subject_info = self._create_intermediate_subject_info()
        self.server_subject_info = subject_info  # 使用传入的服务器信息
        self.client_subject_info = self._create_client_subject_info()

    @staticmethod
    def get_subject_info(subject_info):
        """获取主题信息"""
        start_time = subject_info.get('start_time')
        end_time = subject_info.get('end_time')
        if start_time is not None:
            _time = start_time.replace(tzinfo=ZoneInfo("Asia/Shanghai"))
            utc_time = _time.astimezone(ZoneInfo("UTC"))
            utc_naive = utc_time.replace(tzinfo=None)
            # time_str = utc_naive.strftime("%Y-%m-%d %H:%M:%S.%f")
            subject_info['start_time'] = utc_naive

        if end_time is not None:
            _time = end_time.replace(tzinfo=ZoneInfo("Asia/Shanghai"))
            utc_time = _time.astimezone(ZoneInfo("UTC"))
            utc_naive = utc_time.replace(tzinfo=None)
            # time_str = utc_naive.strftime("%Y-%m-%d %H:%M:%S.%f")
            subject_info['end_time'] = utc_naive
        return dict(subject_info)

    def _create_root_subject_info(self):
        """创建根证书的主题信息"""
        cert_name = self.subject_info.get('cert_name', 'default')
        default_end_time = datetime.datetime.utcnow() + datetime.timedelta(days=3650)
        return {
            'country_code': self.subject_info.get('country_code', 'CN'),
            'organization': self.subject_info.get('organization', 'GY'),
            'cert_name': f'RootCA-{cert_name}',
            'start_time': self.subject_info.get('start_time', datetime.datetime.utcnow()),
            'end_time': self.subject_info.get('end_time', default_end_time)
        }

    def _create_intermediate_subject_info(self):
        """创建中间证书的主题信息"""
        cert_name = self.subject_info.get('cert_name', 'default')
        default_end_time = datetime.datetime.utcnow() + datetime.timedelta(days=1825)
        return {
            'country_code': self.subject_info.get('country_code', 'CN'),
            'organization': self.subject_info.get('organization', 'GY'),
            'cert_name': f'IntermediateCA-{cert_name}',
            'start_time': self.subject_info.get('start_time', datetime.datetime.utcnow()),
            'end_time': self.subject_info.get('end_time', default_end_time)
        }

    def _create_client_subject_info(self):
        """创建客户端证书的主题信息"""
        cert_name = self.subject_info.get('cert_name', 'default')
        default_end_time = datetime.datetime.utcnow() + datetime.timedelta(days=365)
        return {
            'country_code': self.subject_info.get('country_code', 'CN'),
            'organization': self.subject_info.get('organization', 'GY'),
            'cert_name': f'Client-{cert_name}',
            'start_time': self.subject_info.get('start_time', datetime.datetime.utcnow()),
            'end_time': self.subject_info.get('end_time', default_end_time)
        }

    def get_san_list(self):
        """获取主题备用名称列表"""
        cert_name = self.subject_info.get('cert_name', '')
        san_list = []

        if cert_name:
            # 尝试判断是 IP 还是域名
            try:
                ip = ipaddress.ip_address(cert_name)
                san_list.append(f'IP:{cert_name}')
            except ValueError:
                # 如果不是 IP，则作为 DNS 名称
                san_list.append(f'DNS:{cert_name}')

        return san_list

    def generate_crts(self):
        """生成完整的证书链"""

        # 1. 创建根CA - 使用不同的主题信息
        ca_dict = self.generator.create_root_ca(self.root_subject_info)
        self.root_private_key = ca_dict.get('ca_key')
        self.root_private_key_file = ca_dict.get('ca_key_path')
        self.root_cert = ca_dict.get('ca')
        self.root_cert_file = ca_dict.get('ca_path')

        # 2. 创建中间CA的CSR - 使用中间证书的主题信息
        csr_dict = self.generator.create_csr(
            self.intermediate_subject_info,
            is_ca=True,
            file_name='intermediate'
        )
        self.intermediate_csr = csr_dict.get('csr')
        self.intermediate_private_key = csr_dict.get('private_key')
        self.intermediate_private_key_file = csr_dict.get('private_key_path')

        # 3. 根CA签发中间CA证书
        intermediate_dict = self.generator.sign_intermediate_ca_csr(
            self.intermediate_subject_info,
            self.intermediate_csr,
            self.root_private_key,
            self.root_cert
        )
        self.intermediate_cert = intermediate_dict.get('cert')
        self.intermediate_cert_file = intermediate_dict.get('cert_path')

        # 4. 创建服务器证书的CSR - 使用服务器主题信息
        server_csr_dict = self.generator.create_csr(
            self.server_subject_info,
            file_name='server',
            san_list=self.san_list
        )
        self.server_private_key = server_csr_dict.get('private_key')
        self.server_csr = server_csr_dict.get('csr')

        # 5. 中间CA签发服务器证书
        server_cert_dict = self.generator.sign_server_certificate_csr(
            self.server_subject_info,
            self.server_csr,
            self.intermediate_private_key,
            self.intermediate_cert,
            san_list=self.san_list
        )
        self.server_cert = server_cert_dict.get('cert')
        self.server_cert_file = server_cert_dict.get('cert_path')

        # 6. 创建客户端证书的CSR - 使用客户端主题信息
        client_csr_dict = self.generator.create_csr(
            subject_info=self.client_subject_info,
            file_name='client',
        )
        self.client_private_key = client_csr_dict.get('private_key')
        self.client_private_key_file = client_csr_dict.get('private_key_path')
        self.client_csr = client_csr_dict.get('csr')

        # 7. 中间CA签发客户端证书
        client_cert_dict = self.generator.sign_client_certificate_csr(
            self.client_subject_info,
            self.client_csr,
            self.intermediate_private_key,
            self.intermediate_cert
        )
        self.client_cert = client_cert_dict.get('cert')
        self.client_cert_file = client_cert_dict.get('cert_path')

        print("所有证书生成完成！")
        self._verify_certificate_chain()

    def _verify_certificate_chain(self):
        """验证证书链"""
        print("\n=== 验证证书链 ===")

        # 检查根证书
        if self.root_cert:
            root_subject = self.root_cert.subject.rfc4514_string()
            root_issuer = self.root_cert.issuer.rfc4514_string()
            print(f"根证书 - Subject: {root_subject}")
            print(f"根证书 - Issuer: {root_issuer}")
            print(f"根证书 - 是否自签名: {root_subject == root_issuer}")

        # 检查中间证书
        if self.intermediate_cert:
            intermediate_subject = self.intermediate_cert.subject.rfc4514_string()
            intermediate_issuer = self.intermediate_cert.issuer.rfc4514_string()
            print(f"\n中间证书 - Subject: {intermediate_subject}")
            print(f"中间证书 - Issuer: {intermediate_issuer}")
            print(f"中间证书 - 是否由根证书签发: {intermediate_issuer == root_subject}")

        # 检查服务器证书
        if self.server_cert:
            server_subject = self.server_cert.subject.rfc4514_string()
            server_issuer = self.server_cert.issuer.rfc4514_string()
            print(f"\n服务器证书 - Subject: {server_subject}")
            print(f"服务器证书 - Issuer: {server_issuer}")
            print(f"服务器证书 - 是否由中间证书签发: {server_issuer == intermediate_subject}")

        # 检查客户端证书
        if self.client_cert:
            client_subject = self.client_cert.subject.rfc4514_string()
            client_issuer = self.client_cert.issuer.rfc4514_string()
            print(f"\n客户端证书 - Subject: {client_subject}")
            print(f"客户端证书 - Issuer: {client_issuer}")
            print(f"客户端证书 - 是否由中间证书签发: {client_issuer == intermediate_subject}")

    def generate_server_chain(self):
        """生成服务器证书链文件"""
        server_chain_file = self.generator.save_key_and_cert_chain(
            self.server_private_key,
            [self.server_cert, self.intermediate_cert],
            "server_chain.pem",
            encrypt_private_key=False,
        )
        return server_chain_file

    def generate_client_chain(self):
        """生成客户端证书链文件"""
        client_chain_file = self.generator.save_key_and_cert_chain(
            self.client_private_key,
            [self.client_cert, self.intermediate_cert, self.root_cert],
            "client_chain.pem",
            encrypt_private_key=True,
        )
        return client_chain_file

    def generate_full_chain(self):
        """生成完整的证书链（不包含私钥）"""
        full_chain_file = self.generator.save_certificate_chain(
            [self.server_cert, self.intermediate_cert, self.root_cert],
            "full_chain.pem"
        )
        return full_chain_file


class CertificateGeneratorHelper:
    def __init__(self, cert_dir="certificates", is_save_to_file=True, client_key_passphrase: str = ''):
        self.certificates_dir = cert_dir
        self.ensure_directories()
        self.is_save_to_file = is_save_to_file
        sk = str(client_key_passphrase).strip() if client_key_passphrase is not None else ''
        # OpenSSL pkcs12/rsa 等解密 PEM 时要求口令 4～1023 字符；cryptography 加密无此下限，须在此对齐
        if sk and len(sk) < 4:
            raise ValueError('私钥口令若填写则至少 4 个字符')
        # 仅用于客户端证书私钥（*.pem/*.key 中 client 部分）；根/中间/服务端私钥始终明文
        self.client_key_passphrase = sk

    def _client_private_key_encryption_algorithm(self):
        """
        仅客户端证书私钥：填写 client_key_passphrase 时用 BestAvailableEncryption，否则明文。
        """
        if self.client_key_passphrase:
            return serialization.BestAvailableEncryption(self.client_key_passphrase.encode('utf-8'))
        return serialization.NoEncryption()

    def ensure_directories(self):
        """确保证书存储目录存在"""
        if not os.path.exists(self.certificates_dir):
            os.makedirs(self.certificates_dir)

    @staticmethod
    def generate_private_key(key_size=2048):
        """生成私钥"""
        private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=key_size,
            backend=default_backend()
        )
        return private_key

    def create_root_ca(self, subject_info):
        """创建根CA证书（自签名）"""
        private_key = self.generate_private_key()

        subject = x509.Name([
            x509.NameAttribute(NameOID.COUNTRY_NAME, subject_info['country_code']),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, subject_info['organization']),
            x509.NameAttribute(NameOID.COMMON_NAME, subject_info['cert_name']),
        ])

        issuer = subject  # 根证书自签名

        # 确保开始时间早于当前时间
        start_time = subject_info.get('start_time', datetime.datetime.utcnow())
        # if start_time > datetime.datetime.utcnow():
        #     # 如果开始时间在未来，调整到当前时间
        #     start_time = datetime.datetime.utcnow()
        #     print(f"警告：调整根证书开始时间到当前时间")

        certificate = x509.CertificateBuilder().subject_name(
            subject
        ).issuer_name(
            issuer
        ).public_key(
            private_key.public_key()
        ).serial_number(
            x509.random_serial_number()
        ).not_valid_before(
            start_time
        ).not_valid_after(
            subject_info.get('end_time', datetime.datetime.utcnow() + datetime.timedelta(days=3650))
        ).add_extension(
            x509.BasicConstraints(ca=True, path_length=2), critical=True
        ).add_extension(
            x509.KeyUsage(
                digital_signature=True,
                key_cert_sign=True,
                crl_sign=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                encipher_only=False,
                decipher_only=False
            ), critical=True
        ).add_extension(
            x509.SubjectKeyIdentifier.from_public_key(private_key.public_key()),
            critical=False
        ).sign(private_key, hashes.SHA256(), default_backend())

        # 保存证书和私钥
        if self.is_save_to_file:
            ca_key_path = os.path.join(self.certificates_dir, f"{subject_info['cert_name']}_root_key.key")
            with open(ca_key_path, 'wb') as f:
                f.write(private_key.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.TraditionalOpenSSL,
                    encryption_algorithm=serialization.NoEncryption(),
                ))

            ca_cert_path = os.path.join(self.certificates_dir, f"{subject_info['cert_name']}_root_cert.crt")
            with open(ca_cert_path, 'wb') as f:
                f.write(certificate.public_bytes(serialization.Encoding.PEM))
        else:
            ca_key_path = ''
            ca_cert_path = ''

        result = {
            'ca_key': private_key,
            'ca': certificate,
            'ca_key_path': ca_key_path,
            'ca_path': ca_cert_path
        }
        return result

    # 其他方法保持不变...
    def create_csr(self, subject_info, private_key=None, san_list=None, is_ca=False, file_name=None):
        """创建证书签名请求（CSR）"""
        if private_key is None:
            private_key = self.generate_private_key()

        subject = x509.Name([
            x509.NameAttribute(NameOID.COUNTRY_NAME, subject_info['country_code']),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, subject_info['organization']),
            x509.NameAttribute(NameOID.COMMON_NAME, subject_info['cert_name']),
        ])

        builder = x509.CertificateSigningRequestBuilder().subject_name(subject)

        # 添加基本约束
        if is_ca:
            builder = builder.add_extension(
                x509.BasicConstraints(ca=True, path_length=0), critical=True
            )
        else:
            builder = builder.add_extension(
                x509.BasicConstraints(ca=False, path_length=None), critical=True
            )

        # 添加主题备用名称
        if san_list:
            san_extensions = []
            for san in san_list:
                if san.startswith('DNS:'):
                    san_extensions.append(x509.DNSName(san[4:]))
                elif san.startswith('IP:'):
                    # 注意：这里需要处理IP地址的解析
                    ip_str = san[3:]
                    import ipaddress
                    ip = ipaddress.ip_address(ip_str)
                    san_extensions.append(x509.IPAddress(ip))
                elif san.startswith('EMAIL:'):
                    san_extensions.append(x509.RFC822Name(san[6:]))

            if san_extensions:
                builder = builder.add_extension(
                    x509.SubjectAlternativeName(san_extensions), critical=False
                )

        csr = builder.sign(private_key, hashes.SHA256(), default_backend())

        # 保存CSR
        if self.is_save_to_file:
            name_str = file_name if file_name is not None else ''
            csr_filename = f"{subject_info['cert_name']}_{name_str}.csr"
            csr_path = os.path.join(self.certificates_dir, csr_filename)
            with open(csr_path, 'wb') as f:
                f.write(csr.public_bytes(serialization.Encoding.PEM))
            key_filename = f"{subject_info['cert_name']}_{name_str}_key.key"
            key_path = os.path.join(self.certificates_dir, key_filename)
            if file_name == 'client':
                enc = self._client_private_key_encryption_algorithm()
            else:
                enc = serialization.NoEncryption()
            with open(key_path, 'wb') as f:
                f.write(private_key.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.TraditionalOpenSSL,
                    encryption_algorithm=enc,
                ))
        else:
            csr_path = ''
            key_path = ''

        result = {
            'csr': csr,
            'private_key': private_key,
            'csr_path': csr_path,
            'private_key_path': key_path
        }
        return result

    @staticmethod
    def verify_csr(csr):
        """验证CSR签名 - 修复后的版本"""
        try:
            # 正确的方式验证CSR：使用PKCS1v15填充和CSR中指定的哈希算法
            if isinstance(csr.public_key(), rsa.RSAPublicKey):
                # 对于RSA密钥，使用PKCS1v15填充
                csr.public_key().verify(
                    csr.signature,
                    csr.tbs_certrequest_bytes,
                    padding.PKCS1v15(),
                    csr.signature_hash_algorithm
                )
            else:
                # 对于其他类型的密钥，可能需要不同的验证方式
                # 这里我们假设只有RSA密钥
                raise ValueError("不支持的密钥类型")
            return True
        except Exception as e:
            print(f"CSR验证失败: {e}")
            return False

    def sign_intermediate_ca_csr(self, subject_info, csr, root_private_key, root_certificate, validity_days=1825):
        """使用根CA签发中间CA证书（通过CSR）"""
        # 验证CSR签名 - 使用修复后的方法
        if not self.verify_csr(csr):
            raise ValueError("CSR签名验证失败")

        certificate = x509.CertificateBuilder().subject_name(
            csr.subject
        ).issuer_name(
            root_certificate.subject
        ).public_key(
            csr.public_key()
        ).serial_number(
            x509.random_serial_number()
        ).not_valid_before(
            subject_info.get('start_time', datetime.datetime.utcnow())
        ).not_valid_after(
            subject_info.get('end_time', datetime.datetime.utcnow() + datetime.timedelta(days=validity_days))
        ).add_extension(
            x509.BasicConstraints(ca=True, path_length=0), critical=True  # 中间CA不能再签发下级CA
        ).add_extension(
            x509.KeyUsage(
                digital_signature=True,
                key_cert_sign=True,
                crl_sign=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                encipher_only=False,
                decipher_only=False
            ), critical=True
        ).add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(
                root_certificate.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value
            ),
            critical=False
        ).add_extension(
            x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),
            critical=False
        )

        # 复制CSR中的扩展
        for extension in csr.extensions:
            if isinstance(extension.value, x509.BasicConstraints):
                # 我们已经设置了BasicConstraints，跳过
                continue
            certificate = certificate.add_extension(extension.value, critical=extension.critical)

        certificate = certificate.sign(root_private_key, hashes.SHA256(), default_backend())
        intermediate_cert_path = ''
        # 保存中间CA证书
        if self.is_save_to_file:
            # 从CSR的主题中获取通用名称
            common_name = None
            for attr in csr.subject:
                if attr.oid == NameOID.COMMON_NAME:
                    common_name = attr.value
                    break

            if common_name:
                intermediate_cert_path = os.path.join(self.certificates_dir, f"{common_name}_intermediate_cert.crt")
                with open(intermediate_cert_path, 'wb') as f:
                    f.write(certificate.public_bytes(serialization.Encoding.PEM))
                intermediate_cert_path = intermediate_cert_path

        result = {
            'cert': certificate,
            'cert_path': intermediate_cert_path
        }
        return result

    def sign_server_certificate_csr(self, subject_info, csr, ca_private_key, ca_certificate, validity_days=365,
                                    san_list=None):
        """使用CA签发服务器证书（通过CSR）"""
        # 验证CSR签名 - 使用修复后的方法
        if not self.verify_csr(csr):
            raise ValueError("CSR签名验证失败")

        builder = x509.CertificateBuilder().subject_name(
            csr.subject
        ).issuer_name(
            ca_certificate.subject
        ).public_key(
            csr.public_key()
        ).serial_number(
            x509.random_serial_number()
        ).not_valid_before(
            subject_info.get('start_time', datetime.datetime.utcnow())
        ).not_valid_after(
            subject_info.get('end_time', datetime.datetime.utcnow() + datetime.timedelta(days=validity_days))
        ).add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True
        ).add_extension(
            x509.KeyUsage(
                digital_signature=True,
                key_encipherment=True,
                content_commitment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False
            ), critical=True
        ).add_extension(
            x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False
        )

        # 添加权威密钥标识符
        try:
            ski_ext = ca_certificate.extensions.get_extension_for_class(x509.SubjectKeyIdentifier)
            builder = builder.add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(ski_ext.value),
                critical=False
            )
        except x509.ExtensionNotFound:
            # 如果CA证书没有SKI，使用公钥生成
            builder = builder.add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_certificate.public_key()),
                critical=False
            )

        builder = builder.add_extension(
            x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),
            critical=False
        )

        # 处理主题备用名称
        san_extensions = []
        if san_list:
            for san in san_list:
                if san.startswith('DNS:'):
                    san_extensions.append(x509.DNSName(san[4:]))
                elif san.startswith('IP:'):
                    import ipaddress
                    ip = ipaddress.ip_address(san[3:])
                    san_extensions.append(x509.IPAddress(ip))

        # 检查CSR中是否已有SAN扩展
        has_san_in_csr = False
        for extension in csr.extensions:
            if isinstance(extension.value, x509.SubjectAlternativeName):
                has_san_in_csr = True
                # 使用CSR中的SAN
                builder = builder.add_extension(extension.value, critical=extension.critical)
            elif not isinstance(extension.value, x509.BasicConstraints):
                # 复制其他扩展（除了BasicConstraints，因为我们已经设置了）
                builder = builder.add_extension(extension.value, critical=extension.critical)

        # 如果CSR中没有SAN且提供了SAN列表，则添加
        if not has_san_in_csr and san_extensions:
            builder = builder.add_extension(
                x509.SubjectAlternativeName(san_extensions), critical=False
            )

        certificate = builder.sign(ca_private_key, hashes.SHA256(), default_backend())
        certificate_path = ''
        # 保存服务器证书
        if self.is_save_to_file:
            # 从CSR的主题中获取通用名称
            common_name = None
            for attr in csr.subject:
                if attr.oid == NameOID.COMMON_NAME:
                    common_name = attr.value
                    break

            if common_name:
                server_cert_path = os.path.join(self.certificates_dir, f"{common_name}_server_cert.crt")
                with open(server_cert_path, 'wb') as f:
                    f.write(certificate.public_bytes(serialization.Encoding.PEM))
                certificate_path = server_cert_path
        result = {
            'cert': certificate,
            'cert_path': certificate_path
        }

        return result

    def sign_client_certificate_csr(self, subject_info, csr, ca_private_key, ca_certificate, validity_days=365):
        """使用CA签发客户端证书（通过CSR）"""
        # 验证CSR签名 - 使用修复后的方法
        if not self.verify_csr(csr):
            raise ValueError("CSR签名验证失败")

        builder = x509.CertificateBuilder().subject_name(
            csr.subject
        ).issuer_name(
            ca_certificate.subject
        ).public_key(
            csr.public_key()
        ).serial_number(
            x509.random_serial_number()
        ).not_valid_before(
            subject_info.get('start_time', datetime.datetime.utcnow())
        ).not_valid_after(
            subject_info.get('end_time', datetime.datetime.utcnow() + datetime.timedelta(days=validity_days))
        ).add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True
        ).add_extension(
            x509.KeyUsage(
                digital_signature=True,
                key_encipherment=True,
                content_commitment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False
            ), critical=True
        ).add_extension(
            x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False
        )

        # 添加权威密钥标识符
        try:
            ski_ext = ca_certificate.extensions.get_extension_for_class(x509.SubjectKeyIdentifier)
            builder = builder.add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(ski_ext.value),
                critical=False
            )
        except x509.ExtensionNotFound:
            # 如果CA证书没有SKI，使用公钥生成
            builder = builder.add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_certificate.public_key()),
                critical=False
            )

        builder = builder.add_extension(
            x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),
            critical=False
        )

        # 复制CSR中的扩展（除了BasicConstraints）
        for extension in csr.extensions:
            if not isinstance(extension.value, x509.BasicConstraints):
                builder = builder.add_extension(extension.value, critical=extension.critical)

        certificate = builder.sign(ca_private_key, hashes.SHA256(), default_backend())
        client_cert_path = ''
        # 保存客户端证书
        if self.is_save_to_file:
            # 从CSR的主题中获取通用名称
            common_name = None
            for attr in csr.subject:
                if attr.oid == NameOID.COMMON_NAME:
                    common_name = attr.value
                    break

            if common_name:
                client_cert_path = os.path.join(self.certificates_dir, f"{common_name}_client_cert.crt")
                with open(client_cert_path, 'wb') as f:
                    f.write(certificate.public_bytes(serialization.Encoding.PEM))
        result = {
            'cert': certificate,
            'cert_path': client_cert_path
        }
        return result

    def save_certificate_chain(self, certificates, filename):
        """保存证书链到文件"""
        if not self.is_save_to_file:
            return None

        chain_path = os.path.join(self.certificates_dir, filename)
        with open(chain_path, 'wb') as f:
            for cert in certificates:
                f.write(cert.public_bytes(serialization.Encoding.PEM))
        return chain_path

    def save_key_and_cert_chain(self, private_key, certificates, filename, encrypt_private_key=False):
        """保存私钥 + 证书链到一个 PEM 文件（仅用于服务端配置，切勿公开！）"""
        if not self.is_save_to_file:
            return None

        output_path = os.path.join(self.certificates_dir, filename)
        enc = self._client_private_key_encryption_algorithm() if encrypt_private_key else serialization.NoEncryption()
        with open(output_path, 'wb') as f:
            # 先写私钥
            if private_key:
                f.write(private_key.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.TraditionalOpenSSL,
                    encryption_algorithm=enc,
                ))
            # 再写证书链（leaf -> intermediate -> root）
            for cert in certificates:
                if not isinstance(cert, x509.Certificate):
                    raise TypeError(f"Expected x509.Certificate, got {type(cert)}")
                f.write(cert.public_bytes(serialization.Encoding.PEM))
        return output_path

    @staticmethod
    def load_private_key(key_path, password=None):
        """加载私钥"""
        with open(key_path, 'rb') as key_file:
            private_key = serialization.load_pem_private_key(
                key_file.read(),
                password=password,
                backend=default_backend()
            )
        return private_key

    @staticmethod
    def load_certificate(cert_path):
        """加载证书"""
        with open(cert_path, 'rb') as cert_file:
            certificate = x509.load_pem_x509_certificate(
                cert_file.read(),
                backend=default_backend()
            )
        return certificate

    @staticmethod
    def load_csr(csr_path):
        """加载CSR"""
        with open(csr_path, 'rb') as csr_file:
            csr = x509.load_pem_x509_csr(
                csr_file.read(),
                backend=default_backend()
            )
        return csr

    # 使用示例
def demo_usage():
    generator = CertificateGenerator()

    try:
        # 1. 创建根CA
        print("1. 创建根CA...")
        root_private_key, root_cert = generator.create_root_ca({
            'common_name': 'MyCompanyRootCA',
            'organization': 'MyCompany',
            'country': 'US'
        })

        # 2. 创建中间CA的CSR
        print("2. 创建中间CA的CSR...")
        intermediate_private_key, intermediate_csr = generator.create_csr({
            'common_name': 'MyCompanyIntermediateCA',
            'organization': 'MyCompany',
            'country': 'US'
        }, is_ca=True)

        # 3. 根CA签发中间CA证书
        print("3. 根CA签发中间CA证书...")
        intermediate_cert = generator.sign_intermediate_ca_csr(
            intermediate_csr, root_private_key, root_cert
        )

        # 4. 创建服务器证书的CSR
        print("4. 创建服务器证书的CSR...")
        server_private_key, server_csr = generator.create_csr({
            'common_name': 'api.example.com',
            'organization': 'MyCompany',
            'country': 'US'
        }, san_list=['DNS:api.example.com', 'DNS:www.example.com'])

        # 5. 中间CA签发服务器证书
        print("5. 中间CA签发服务器证书...")
        server_cert = generator.sign_server_certificate_csr(
            server_csr, intermediate_private_key, intermediate_cert,
            san_list=['DNS:api.example.com', 'DNS:www.example.com']
        )

        # 6. 创建客户端证书的CSR
        print("6. 创建客户端证书的CSR...")
        client_private_key, client_csr = generator.create_csr({
            'common_name': 'client@example.com',
            'organization': 'MyCompany',
            'country': 'US'
        })

        # 7. 中间CA签发客户端证书
        print("7. 中间CA签发客户端证书...")
        client_cert = generator.sign_client_certificate_csr(
            client_csr, intermediate_private_key, intermediate_cert
        )

        # 8. 保存证书链
        print("8. 保存证书链...")
        generator.save_certificate_chain(
            [server_cert, intermediate_cert],
            "server_chain.pem"
        )

        print("私钥和证书链已保存到文件")
        # 9. 保存私钥和证书链（仅用于服务端配置，切勿公开！）
        generator.save_key_and_cert_chain(
            server_private_key,
            [server_cert, intermediate_cert],
            "key_and_server_cert_chain.pem"
        )

        # 10. 新增：生成客户端 PEM 文件（用于 PyMySQL 连接）
        print("10. 生成客户端 PEM 文件...")
        generator.save_key_and_cert_chain(
            # client_private_key,
            '',
            [client_cert, intermediate_cert, root_cert],  # 包含完整的证书链
            "client.pem"  # 这个文件将包含私钥 + 客户端证书 + 中间CA + 根CA
        )
        print("所有证书生成完成！")

    except Exception as e:
        print(f"证书生成过程中出现错误: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    # 在你的视图中这样调用

    # 准备主题信息
    # _info = {
    #     'country_code': 'CN',
    #     'organization': 'GY',
    #     'cert_name': '10.4.0.170',  # 或 'your-domain.com'
    #     'start_time': datetime.datetime.utcnow(),  # 确保开始时间是当前时间
    #     'end_time': datetime.datetime.utcnow() + datetime.timedelta(days=365)
    # }

    # start_time_, end_time_ = TimeUtils.get_period_time(period=int(7))
    # start_time_ = start_time_.replace(tzinfo=None)
    # end_time_ = end_time_.replace(tzinfo=None)
    # _info = {'cert_name': 'zzz', 'password': 'asdfas', 'organization': 'GY', 'period_type': 2,
    #  'start_time': datetime.datetime(2025, 12, 22, 8, 43, 36), 'end_time': datetime.datetime(2025, 12, 22, 8, 43, 36),
    #  'cert_format': ['PEM', 'KEY', 'CRT'], 'country_code': 'CN', 'source': 'generate', 'username': 'asdf',
    #  'secret_key': ''}
    start_time_ = datetime.datetime(2025, 12, 22, 8, 43, 36)
    end_time_ = datetime.datetime(2025, 12, 22, 8, 43, 36)
    print(start_time_)
    print(datetime.datetime.utcnow())

    _info = {'cert_name': '10.4.0.170',
             #'password': 'asdfas',
             'organization': 'GY',
             'period_type': 2,
             'start_time': start_time_,
             'end_time': end_time_,
             #'cert_format': ['PEM', 'KEY', 'CRT'],
             'country_code': 'CN',
             #'source': 'generate',
             #'username': 'asdf',
             #'secret_key': ''
             }

    # 生成证书
    dir_path = '/home/kopok/Documents/升级包存放/aaa'
    generator = CertificateGenerator(cert_dir=dir_path, subject_info=_info)
    generator.generate_crts()

    # 生成服务器证书链
    server_chain = generator.generate_server_chain()
    print(f"服务器证书链: {server_chain}")

    # 生成客户端证书链
    client_chain = generator.generate_client_chain()
    print(f"客户端证书链: {client_chain}")

    # 生成完整证书链
    full_chain = generator.generate_full_chain()
    print(f"完整证书链: {full_chain}")
    # dir_path = '/home/kopok/Documents/升级包存放'
    # generator = CertificateGenerator(cert_dir=dir_path, subject_info={'cert_name': 'as'})
    # generator.generate_crts()
    # server_chain = generator.generate_server_chain()
    # generator.generate_client_chain()
        # demo_usage()
        # obj = CertificateGenerator()
        # key = obj.load_private_key(key_path='certificates/client@example.com.key', password=None)
        # cert = obj.load_certificate(cert_path='certificates/client@example.com_client.crt')
        # m_cert = obj.load_certificate(cert_path='certificates/MyCompanyIntermediateCA_intermediate.crt')
        # root_cert = obj.load_certificate(cert_path='certificates/MyCompanyIntermediateCA_intermediate.crt')
        # obj.save_key_and_cert_chain(
        #     '',
        #     [cert,m_cert, root_cert],  # 包含完整的证书链
        #     "client_chain.pem"  # 这个文件将包含私钥 + 客户端证书 + 中间CA + 根CA
        # )
