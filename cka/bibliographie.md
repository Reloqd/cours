---
title: "CKA — Bibliographie"
description: "Sources officielles du cours CKA v1.37, groupées par thème, avec version concernée et date de consultation."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## Bibliographie

Toutes les sources ci-dessous sont officielles : documentation des projets, notes de version, pages de la CNCF et de la Linux Foundation. Les blogs tiers, même excellents, n'ont servi à vérifier aucun fait du cours. Chaque adresse a été ouverte le 23 octobre 2026 et répondait alors normalement ; la version indiquée est celle à laquelle la page s'applique ce jour-là. Pendant l'examen, seuls `kubernetes.io/docs`, `kubernetes.io/blog`, `helm.sh/docs` et `gateway-api.sigs.k8s.io` sont accessibles : les autres sources servent à la préparation.

### Examen et programme

Pages de la CNCF et de la Linux Foundation qui définissent l'examen : programme, inscription, règles du jour J et ressources autorisées.

- « CKA Curriculum v1.37 (PDF) ». <https://github.com/cncf/curriculum/blob/master/CKA_Curriculum_v1.37.pdf>. Version : programme CKA v1.37. Consulté le 23 octobre 2026.
- « cncf/curriculum : Open Source Curriculum for CNCF Certification Courses ». <https://github.com/cncf/curriculum>. Version : programmes CNCF, version v1.37 pour le CKA. Consulté le 23 octobre 2026.
- « Certified Kubernetes Administrator (CKA) - Linux Foundation - Education ». <https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/>. Version : examen CKA, Kubernetes v1.37 (inscription, prix, contenu). Consulté le 23 octobre 2026.
- « Important Instructions: CKA and CKAD ». <https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad>. Version : examen CKA, Kubernetes v1.37. Consulté le 23 octobre 2026.
- « Resources Allowed: All LF Certification Programs ». <https://docs.linuxfoundation.org/tc-docs/certification/certification-resources-allowed>. Version : examen CKA, Kubernetes v1.37. Consulté le 23 octobre 2026.
- « Frequently Asked Questions: CKA and CKAD & CKS ». <https://docs.linuxfoundation.org/tc-docs/certification/faq-cka-ckad-cks>. Version : examen CKA, Kubernetes v1.37. Consulté le 23 octobre 2026.
- « Linux Foundation Certification Exam: Candidate Handbook (using PSI BRIDGE Proctoring platform) ». <https://docs.linuxfoundation.org/tc-docs/certification/lf-handbook2>. Version : manuel du candidat, plateforme PSI Bridge. Consulté le 23 octobre 2026.
- « Candidate Requirements ». <https://docs.linuxfoundation.org/tc-docs/certification/lf-handbook2/candidate-requirements>. Version : manuel du candidat, plateforme PSI Bridge. Consulté le 23 octobre 2026.
- « Exam Preparation Checklist ». <https://docs.linuxfoundation.org/tc-docs/certification/lf-handbook2/exam-preparation-checklist>. Version : manuel du candidat, plateforme PSI Bridge. Consulté le 23 octobre 2026.
- « Exam User Interface: Configuration & Features ». <https://docs.linuxfoundation.org/tc-docs/certification/lf-handbook2/exam-user-interface>. Version : manuel du candidat, plateforme PSI Bridge. Consulté le 23 octobre 2026.
- « CKA Simulator | Killer Shell ». <https://killer.sh/cka>. Version : simulateur CKA (deux sessions incluses dans l'inscription). Consulté le 23 octobre 2026.

### Kubernetes 1.35 à 1.37 : versions et notes de version

Ce qui a changé entre les versions que le cours cite, et les règles de cycle de vie.

- « Kubernetes v1.37: Garhwal ». <https://kubernetes.io/blog/2026/08/26/kubernetes-v1-37-release/>. Version : Kubernetes v1.37. Consulté le 23 octobre 2026.
- « CHANGELOG-1.37.md ». <https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.37.md>. Version : Kubernetes v1.37.0 et v1.37.1. Consulté le 23 octobre 2026.
- « Kubernetes v1.36: ハル (Haru) ». <https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/>. Version : Kubernetes v1.36. Consulté le 23 octobre 2026.
- « CHANGELOG-1.36.md ». <https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.36.md>. Version : Kubernetes v1.36.x. Consulté le 23 octobre 2026.
- « Kubernetes v1.35: Timbernetes (The World Tree Release) ». <https://kubernetes.io/blog/2025/12/17/kubernetes-v1-35-release/>. Version : Kubernetes v1.35. Consulté le 23 octobre 2026.
- « CHANGELOG-1.35.md ». <https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.35.md>. Version : Kubernetes v1.35.x. Consulté le 23 octobre 2026.
- « Kubernetes v1.37: Metrics API graduates to stable ». <https://kubernetes.io/blog/2026/08/27/kubernetes-v1-37-metrics-api-ga/>. Version : Kubernetes v1.37. Consulté le 23 octobre 2026.
- « Kubernetes v1.36: Deprecation and removal of Service ExternalIPs ». <https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/>. Version : Kubernetes v1.36. Consulté le 23 octobre 2026.
- « Kubernetes v1.33: Continuing the transition from Endpoints to EndpointSlices ». <https://kubernetes.io/blog/2025/04/24/endpoints-deprecation/>. Version : Kubernetes v1.33 et suivantes. Consulté le 23 octobre 2026.
- « Releases ». <https://kubernetes.io/releases/>. Version : versions maintenues au 23 octobre 2026 (1.35 à 1.37). Consulté le 23 octobre 2026.
- « Patch Releases ». <https://kubernetes.io/releases/patch-releases/>. Version : correctifs v1.37.1, v1.36.5, v1.35.9. Consulté le 23 octobre 2026.
- « Version Skew Policy ». <https://kubernetes.io/releases/version-skew-policy/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Deprecated API Migration Guide ». <https://kubernetes.io/docs/reference/using-api/deprecation-guide/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.

### Documentation Kubernetes v1.37, par chapitre

Pages de kubernetes.io/docs, toutes autorisées pendant l'examen. La documentation en ligne correspond à la v1.37 depuis le 26 août 2026.

#### Fondations (chapitres 2 et 3)

- « Kubernetes Documentation ». <https://kubernetes.io/docs/home/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Cluster Architecture ». <https://kubernetes.io/docs/concepts/architecture/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Kubernetes Components ». <https://kubernetes.io/docs/concepts/overview/components/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « The Kubernetes API ». <https://kubernetes.io/docs/concepts/overview/kubernetes-api/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Controlling Access to the Kubernetes API ». <https://kubernetes.io/docs/concepts/security/controlling-access/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Controllers ». <https://kubernetes.io/docs/concepts/architecture/controller/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Create static Pods ». <https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Objects In Kubernetes ». <https://kubernetes.io/docs/concepts/overview/working-with-objects/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Namespaces ». <https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Finalizers ». <https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Garbage Collection ». <https://kubernetes.io/docs/concepts/architecture/garbage-collection/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Command line tool (kubectl) ». <https://kubernetes.io/docs/reference/kubectl/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « kubectl Quick Reference ». <https://kubernetes.io/docs/reference/kubectl/quick-reference/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « JSONPath Support ». <https://kubernetes.io/docs/reference/kubectl/jsonpath/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « kubectl Usage Conventions ». <https://kubernetes.io/docs/reference/kubectl/conventions/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Kubectl user preferences (kuberc) ». <https://kubernetes.io/docs/reference/kubectl/kuberc/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Organizing Cluster Access Using kubeconfig Files ». <https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Configure Access to Multiple Clusters ». <https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Managing Kubernetes Objects Using Imperative Commands ». <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/imperative-command/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Declarative Management of Kubernetes Objects Using Configuration Files ». <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Server-Side Apply ». <https://kubernetes.io/docs/reference/using-api/server-side-apply/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Well-Known Labels, Annotations and Taints ». <https://kubernetes.io/docs/reference/labels-annotations-taints/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.

#### Charges de travail et ordonnancement (chapitres 4 à 8)

- « Pods ». <https://kubernetes.io/docs/concepts/workloads/pods/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Pod Lifecycle ». <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Init Containers ». <https://kubernetes.io/docs/concepts/workloads/pods/init-containers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Sidecar Containers ». <https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Ephemeral Containers ». <https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Configure Liveness, Readiness and Startup Probes ». <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Resource Management for Pods and Containers ». <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Pod Quality of Service Classes ». <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Resize CPU and Memory Resources assigned to Containers ». <https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Configure a Security Context for a Pod or Container ». <https://kubernetes.io/docs/tasks/configure-pod-container/security-context/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « ReplicaSet ». <https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Deployments ». <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « DaemonSet ». <https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « StatefulSets ». <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Jobs ». <https://kubernetes.io/docs/concepts/workloads/controllers/job/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « CronJob ». <https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Disruptions ». <https://kubernetes.io/docs/concepts/workloads/pods/disruptions/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Specifying a Disruption Budget for your Application ». <https://kubernetes.io/docs/tasks/run-application/configure-pdb/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « ConfigMaps ». <https://kubernetes.io/docs/concepts/configuration/configmap/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Configure a Pod to Use a ConfigMap ». <https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Secrets ». <https://kubernetes.io/docs/concepts/configuration/secret/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Distribute Credentials Securely Using Secrets ». <https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Downward API ». <https://kubernetes.io/docs/concepts/workloads/pods/downward-api/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Projected Volumes ». <https://kubernetes.io/docs/concepts/storage/projected-volumes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Encrypting Confidential Data at Rest ». <https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Autoscaling Workloads ». <https://kubernetes.io/docs/concepts/workloads/autoscaling/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Horizontal Pod Autoscaling ». <https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « HorizontalPodAutoscaler Walkthrough ». <https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Vertical Pod Autoscaling ». <https://kubernetes.io/docs/concepts/workloads/autoscaling/vertical-pod-autoscale/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Resource metrics pipeline ». <https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Kubernetes Scheduler ». <https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Assigning Pods to Nodes ». <https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Assign Pods to Nodes using Node Affinity ». <https://kubernetes.io/docs/tasks/configure-pod-container/assign-pods-nodes-using-node-affinity/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Taints and Tolerations ». <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Pod Topology Spread Constraints ». <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Pod Priority and Preemption ». <https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Resource Quotas ». <https://kubernetes.io/docs/concepts/policy/resource-quotas/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Limit Ranges ». <https://kubernetes.io/docs/concepts/policy/limit-range/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Admission Control in Kubernetes ». <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Pod Security Admission ». <https://kubernetes.io/docs/concepts/security/pod-security-admission/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Pod Security Standards ». <https://kubernetes.io/docs/concepts/security/pod-security-standards/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Safely Drain a Node ». <https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « API-initiated Eviction ». <https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.

#### Services et réseau (chapitres 9 à 14)

- « Services, Load Balancing, and Networking ». <https://kubernetes.io/docs/concepts/services-networking/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Cluster Networking ». <https://kubernetes.io/docs/concepts/cluster-administration/networking/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Network Plugins ». <https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Service ». <https://kubernetes.io/docs/concepts/services-networking/service/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « EndpointSlices ». <https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Service ClusterIP allocation ». <https://kubernetes.io/docs/concepts/services-networking/cluster-ip-allocation/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Virtual IPs and Service Proxies ». <https://kubernetes.io/docs/reference/networking/virtual-ips/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Ports and Protocols ». <https://kubernetes.io/docs/reference/networking/ports-and-protocols/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Use Port Forwarding to Access Applications in a Cluster ». <https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « DNS for Services and Pods ». <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Using CoreDNS for Service Discovery ». <https://kubernetes.io/docs/tasks/administer-cluster/coredns/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Customizing DNS Service ». <https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Debugging DNS Resolution ». <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Using NodeLocal DNSCache in Kubernetes Clusters ». <https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Ingress ». <https://kubernetes.io/docs/concepts/services-networking/ingress/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Ingress Controllers ». <https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Gateway API ». <https://kubernetes.io/docs/concepts/services-networking/gateway/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Network Policies ». <https://kubernetes.io/docs/concepts/services-networking/network-policies/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Declare Network Policy ». <https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.

#### Stockage (chapitre 15)

- « Volumes ». <https://kubernetes.io/docs/concepts/storage/volumes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Ephemeral Volumes ». <https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Persistent Volumes ». <https://kubernetes.io/docs/concepts/storage/persistent-volumes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Storage Classes ». <https://kubernetes.io/docs/concepts/storage/storage-classes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Change the default StorageClass ». <https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Dynamic Volume Provisioning ». <https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Volume Snapshots ». <https://kubernetes.io/docs/concepts/storage/volume-snapshots/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Volume Snapshot Classes ». <https://kubernetes.io/docs/concepts/storage/volume-snapshot-classes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Configure a Pod to Use a Volume for Storage ». <https://kubernetes.io/docs/tasks/configure-pod-container/configure-volume-storage/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.

#### Architecture, installation et configuration (chapitres 16 à 20)

- « Authenticating ». <https://kubernetes.io/docs/reference/access-authn-authz/authentication/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Authorization ». <https://kubernetes.io/docs/reference/access-authn-authz/authorization/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Using RBAC Authorization ». <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Using Node Authorization ». <https://kubernetes.io/docs/reference/access-authn-authz/node/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Certificates and Certificate Signing Requests ». <https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Service Accounts ». <https://kubernetes.io/docs/concepts/security/service-accounts/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Configure Service Accounts for Pods ». <https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Managing Service Accounts ». <https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Declarative Management of Kubernetes Objects Using Kustomize ». <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Container Runtime Interface (CRI) ». <https://kubernetes.io/docs/concepts/containers/cri/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Runtime Class ». <https://kubernetes.io/docs/concepts/containers/runtime-class/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Debugging Kubernetes nodes with crictl ». <https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Extending Kubernetes ». <https://kubernetes.io/docs/concepts/extend-kubernetes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Custom Resources ». <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Extend the Kubernetes API with CustomResourceDefinitions ». <https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Kubernetes API Aggregation Layer ». <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Operator pattern ». <https://kubernetes.io/docs/concepts/extend-kubernetes/operator/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Dynamic Admission Control ». <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Device Plugins ». <https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Container Runtimes ». <https://kubernetes.io/docs/setup/production-environment/container-runtimes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Installing kubeadm ». <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>. Version : Kubernetes v1.37 (documentation courante), dépôt pkgs.k8s.io v1.37. Consulté le 23 octobre 2026.
- « Creating a cluster with kubeadm ». <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Options for Highly Available Topology ». <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Creating Highly Available Clusters with kubeadm ». <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Upgrading kubeadm clusters ». <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/>. Version : Kubernetes v1.37 (documentation courante) (1.36 vers 1.37). Consulté le 23 octobre 2026.
- « Upgrading Linux nodes ». <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Certificate Management with kubeadm ». <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Reconfiguring a kubeadm cluster ». <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-reconfigure/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Kubeadm ». <https://kubernetes.io/docs/reference/setup-tools/kubeadm/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « kubeadm Configuration (v1beta4) ». <https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/>. Version : Kubernetes v1.37 (documentation courante), API kubeadm v1beta4. Consulté le 23 octobre 2026.
- « PKI certificates and requirements ». <https://kubernetes.io/docs/setup/best-practices/certificates/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Operating etcd clusters for Kubernetes ». <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>. Version : Kubernetes v1.37 (documentation courante) (voir la réserve sur etcdctl, annexe A.11). Consulté le 23 octobre 2026.

#### Dépannage (chapitres 21 à 23)

- « Logging Architecture ». <https://kubernetes.io/docs/concepts/cluster-administration/logging/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « System Logs ». <https://kubernetes.io/docs/concepts/cluster-administration/system-logs/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « kubectl logs ». <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/>. Version : kubectl v1.37. Consulté le 23 octobre 2026.
- « kubectl events ». <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_events/>. Version : kubectl v1.37. Consulté le 23 octobre 2026.
- « kubectl debug ». <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_debug/>. Version : kubectl v1.37. Consulté le 23 octobre 2026.
- « Tools for Monitoring Resources ». <https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-usage-monitoring/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Monitoring, Logging, and Debugging ». <https://kubernetes.io/docs/tasks/debug/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Troubleshooting Applications ». <https://kubernetes.io/docs/tasks/debug/debug-application/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Debug Pods ». <https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Debug Running Pods ». <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Debug Init Containers ». <https://kubernetes.io/docs/tasks/debug/debug-application/debug-init-containers/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Determine the Reason for Pod Failure ». <https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Debug Services ». <https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Troubleshooting Clusters ». <https://kubernetes.io/docs/tasks/debug/debug-cluster/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Debugging Kubernetes Nodes With Kubectl ». <https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Nodes ». <https://kubernetes.io/docs/concepts/architecture/nodes/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Node Status ». <https://kubernetes.io/docs/reference/node/node-status/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Leases ». <https://kubernetes.io/docs/concepts/architecture/leases/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Node-pressure Eviction ». <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Set Kubelet Parameters Via A Configuration File ». <https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « Kubelet Configuration (v1beta1) ». <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « kubelet ». <https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.
- « kube-apiserver ». <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/>. Version : Kubernetes v1.37 (documentation courante). Consulté le 23 octobre 2026.

### etcd 3.7

La sauvegarde et la restauration du chapitre 20 suivent la documentation d'etcd 3.7 ; la suppression de `etcdctl snapshot restore` et `status` est consignée dans le journal des changements de la 3.6.

- « v3.7 docs ». <https://etcd.io/docs/v3.7/>. Version : etcd v3.7. Consulté le 23 octobre 2026.
- « Disaster recovery ». <https://etcd.io/docs/v3.7/op-guide/recovery/>. Version : etcd v3.7. Consulté le 23 octobre 2026.
- « Maintenance ». <https://etcd.io/docs/v3.7/op-guide/maintenance/>. Version : etcd v3.7. Consulté le 23 octobre 2026.
- « Install ». <https://etcd.io/docs/v3.7/install/>. Version : etcd v3.7. Consulté le 23 octobre 2026.
- « Release v3.7.0 · etcd-io/etcd ». <https://github.com/etcd-io/etcd/releases/tag/v3.7.0>. Version : etcd v3.7.0 (version posée par kubeadm 1.37). Consulté le 23 octobre 2026.
- « CHANGELOG-3.7.md ». <https://github.com/etcd-io/etcd/blob/main/CHANGELOG/CHANGELOG-3.7.md>. Version : etcd v3.7.x. Consulté le 23 octobre 2026.
- « CHANGELOG-3.6.md ». <https://github.com/etcd-io/etcd/blob/main/CHANGELOG/CHANGELOG-3.6.md>. Version : etcd v3.6.x. Consulté le 23 octobre 2026.
- « Announcing etcd v3.7.0 ». <https://kubernetes.io/blog/2026/07/08/announcing-etcd-3.7/>. Version : etcd v3.7.0. Consulté le 23 octobre 2026.

### Helm 4 et Kustomize

helm.sh/docs fait partie des ressources autorisées à l'examen.

- « Docs Home ». <https://helm.sh/docs/>. Version : Helm v4.3. Consulté le 23 octobre 2026.
- « Helm 4 Overview ». <https://helm.sh/docs/overview/>. Version : Helm v4. Consulté le 23 octobre 2026.
- « Helm 4 Released ». <https://helm.sh/blog/helm-4-released/>. Version : Helm v4.0 (17 novembre 2025) et fin de support de Helm 3. Consulté le 23 octobre 2026.
- « Installing Helm ». <https://helm.sh/docs/intro/install/>. Version : Helm v4.3. Consulté le 23 octobre 2026.
- « Using Helm ». <https://helm.sh/docs/intro/using_helm/>. Version : Helm v4.3. Consulté le 23 octobre 2026.
- « helm install ». <https://helm.sh/docs/helm/helm_install/>. Version : Helm v4.3. Consulté le 23 octobre 2026.
- « helm upgrade ». <https://helm.sh/docs/helm/helm_upgrade/>. Version : Helm v4.3. Consulté le 23 octobre 2026.
- « helm rollback ». <https://helm.sh/docs/helm/helm_rollback/>. Version : Helm v4.3. Consulté le 23 octobre 2026.
- « Use OCI-based registries ». <https://helm.sh/docs/topics/registries/>. Version : Helm v4.3. Consulté le 23 octobre 2026.
- « Release Helm v4.3.1 · helm/helm ». <https://github.com/helm/helm/releases/tag/v4.3.1>. Version : Helm v4.3.1. Consulté le 23 octobre 2026.
- « Kustomize ». <https://kubectl.docs.kubernetes.io/references/kustomize/>. Version : Kustomize v5. Consulté le 23 octobre 2026.
- « The Kustomization File ». <https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/>. Version : Kustomize v5. Consulté le 23 octobre 2026.
- « kubernetes-sigs/kustomize ». <https://github.com/kubernetes-sigs/kustomize>. Version : Kustomize v5.8.1. Consulté le 23 octobre 2026.
- « Release kustomize/v5.8.1 · kubernetes-sigs/kustomize ». <https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2Fv5.8.1>. Version : Kustomize v5.8.1 (intégré à kubectl 1.37). Consulté le 23 octobre 2026.

### Gateway API v1.6 et Envoy Gateway

gateway-api.sigs.k8s.io fait partie des ressources autorisées au CKA.

- « Gateway API ». <https://gateway-api.sigs.k8s.io/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Getting started with Gateway API ». <https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « API Overview ». <https://gateway-api.sigs.k8s.io/docs/concepts/api-overview/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Roles and Personas ». <https://gateway-api.sigs.k8s.io/docs/concepts/roles-and-personas/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Versioning ». <https://gateway-api.sigs.k8s.io/docs/concepts/versioning/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Troubleshooting and Status ». <https://gateway-api.sigs.k8s.io/docs/concepts/troubleshooting/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « GatewayClass ». <https://gateway-api.sigs.k8s.io/reference/api-types/gatewayclass/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Gateway ». <https://gateway-api.sigs.k8s.io/reference/api-types/gateway/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « HTTPRoute ». <https://gateway-api.sigs.k8s.io/reference/api-types/httproute/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « ReferenceGrant ». <https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « API Reference (v1.6) ». <https://gateway-api.sigs.k8s.io/reference/api-spec/1.6/spec/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « HTTP routing ». <https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « HTTP traffic splitting ». <https://gateway-api.sigs.k8s.io/guides/user-guides/traffic-splitting/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « HTTP path redirects and rewrites ». <https://gateway-api.sigs.k8s.io/guides/user-guides/http-redirect-rewrite/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « HTTP Header Modifiers ». <https://gateway-api.sigs.k8s.io/guides/user-guides/http-header-modifier/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « TLS Configuration ». <https://gateway-api.sigs.k8s.io/guides/user-guides/tls/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Migrating from Ingress ». <https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « A Welcome Guide for Ingress-NGINX Users ». <https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress-nginx/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Release v1.6.3 · kubernetes-sigs/gateway-api ». <https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.3>. Version : Gateway API v1.6.3. Consulté le 23 octobre 2026.
- « Gateway API v1.6: TCPRoute and UDPRoute Graduate to Standard ». <https://kubernetes.io/blog/2026/08/03/gateway-api-v1-6-release/>. Version : Gateway API v1.6. Consulté le 23 octobre 2026.
- « Install with Helm ». <https://gateway.envoyproxy.io/docs/install/install-helm/>. Version : Envoy Gateway v1.9.2. Consulté le 23 octobre 2026.
- « Quickstart ». <https://gateway.envoyproxy.io/docs/tasks/quickstart/>. Version : Envoy Gateway v1.9.2. Consulté le 23 octobre 2026.
- « Compatibility Matrix ». <https://gateway.envoyproxy.io/news/releases/matrix/>. Version : Envoy Gateway v1.9 (testé sur Kubernetes 1.33 à 1.36). Consulté le 23 octobre 2026.
- « Release v1.9.2 · envoyproxy/gateway ». <https://github.com/envoyproxy/gateway/releases/tag/v1.9.2>. Version : Envoy Gateway v1.9.2. Consulté le 23 octobre 2026.

### Ingress : le retrait d'ingress-nginx

- « Ingress NGINX Retirement: What You Need to Know ». <https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/>. Version : ingress-nginx, retrait effectif le 24 mars 2026. Consulté le 23 octobre 2026.
- « Ingress NGINX: Statement from the Kubernetes Steering and Security Response Committees ». <https://kubernetes.io/blog/2026/01/29/ingress-nginx-statement/>. Version : ingress-nginx. Consulté le 23 octobre 2026.
- « Announcing Ingress2Gateway 1.0: Your Path to Gateway API ». <https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/>. Version : ingress2gateway v1.0. Consulté le 23 octobre 2026.
- « kubernetes/ingress-nginx ». <https://github.com/kubernetes/ingress-nginx>. Version : ingress-nginx v1.15.1 (dépôt archivé). Consulté le 23 octobre 2026.

### Réseau : CNI, Calico, CoreDNS, MetalLB

- « CNI Specification ». <https://www.cni.dev/docs/spec/>. Version : spécification CNI 1.x. Consulté le 23 octobre 2026.
- « containernetworking/cni : SPEC.md ». <https://github.com/containernetworking/cni/blob/main/SPEC.md>. Version : spécification CNI 1.x. Consulté le 23 octobre 2026.
- « About Calico ». <https://docs.tigera.io/calico/latest/about/>. Version : Calico v3.32. Consulté le 23 octobre 2026.
- « IP address management ». <https://docs.tigera.io/calico/latest/networking/ipam/>. Version : Calico v3.32. Consulté le 23 octobre 2026.
- « Calico Open Source release notes ». <https://docs.tigera.io/calico/latest/release-notes/>. Version : Calico v3.32. Consulté le 23 octobre 2026.
- « Release v3.32.2 · projectcalico/calico ». <https://github.com/projectcalico/calico/releases/tag/v3.32.2>. Version : Calico v3.32.2 (manifeste de minikube v1.39.0). Consulté le 23 octobre 2026.
- « Kubernetes DNS-Based Service Discovery (specification.md) ». <https://github.com/kubernetes/dns/blob/master/docs/specification.md>. Version : spécification DNS de Kubernetes. Consulté le 23 octobre 2026.
- « CoreDNS: DNS and Service Discovery ». <https://coredns.io/manual/toc/>. Version : CoreDNS v1.14. Consulté le 23 octobre 2026.
- « CoreDNS plugin hosts ». <https://coredns.io/plugins/hosts/>. Version : CoreDNS v1.14. Consulté le 23 octobre 2026.
- « CoreDNS plugin forward ». <https://coredns.io/plugins/forward/>. Version : CoreDNS v1.14. Consulté le 23 octobre 2026.
- « MetalLB :: MetalLB, bare metal load-balancer for Kubernetes ». <https://metallb.io/>. Version : MetalLB (documentation courante, à CRD). Consulté le 23 octobre 2026.
- « GitHub - metallb/metallb at v0.9.6 ». <https://github.com/metallb/metallb/tree/v0.9.6>. Version : MetalLB v0.9.6, configuration par ConfigMap (addon minikube). Consulté le 23 octobre 2026.
- « Release v0.9.6 · metallb/metallb ». <https://github.com/metallb/metallb/releases/tag/v0.9.6>. Version : MetalLB v0.9.6. Consulté le 23 octobre 2026.

### Stockage : CSI

- « Introduction - Kubernetes CSI Developer Documentation ». <https://kubernetes-csi.github.io/docs/>. Version : CSI 1.x, sidecars Kubernetes. Consulté le 23 octobre 2026.
- « container-storage-interface/spec : spec.md ». <https://github.com/container-storage-interface/spec/blob/master/spec.md>. Version : spécification CSI. Consulté le 23 octobre 2026.
- « kubernetes-csi/csi-driver-host-path ». <https://github.com/kubernetes-csi/csi-driver-host-path>. Version : hostpathplugin v1.9.0 (addon csi-hostpath-driver). Consulté le 23 octobre 2026.

### Le lab : minikube, metrics-server, runtime

- « Welcome! ». <https://minikube.sigs.k8s.io/docs/>. Version : minikube v1.39.0. Consulté le 23 octobre 2026.
- « minikube start ». <https://minikube.sigs.k8s.io/docs/start/>. Version : minikube v1.39.0. Consulté le 23 octobre 2026.
- « docker ». <https://minikube.sigs.k8s.io/docs/drivers/docker/>. Version : minikube v1.39.0. Consulté le 23 octobre 2026.
- « Using Multi-Node Clusters ». <https://minikube.sigs.k8s.io/docs/tutorials/multi_node/>. Version : minikube v1.39.0. Consulté le 23 octobre 2026.
- « Addons ». <https://minikube.sigs.k8s.io/docs/handbook/addons/>. Version : minikube v1.39.0. Consulté le 23 octobre 2026.
- « Network Policy ». <https://minikube.sigs.k8s.io/docs/handbook/network_policy/>. Version : minikube v1.39.0. Consulté le 23 octobre 2026.
- « CSI Driver and Volume Snapshots ». <https://minikube.sigs.k8s.io/docs/tutorials/volume_snapshots_and_csi/>. Version : minikube v1.39.0. Consulté le 23 octobre 2026.
- « Release v1.39.0 · kubernetes/minikube ». <https://github.com/kubernetes/minikube/releases/tag/v1.39.0>. Version : minikube v1.39.0 (Kubernetes v1.37.0 par défaut, containerd 2.3.4). Consulté le 23 octobre 2026.
- « kubernetes-sigs/metrics-server ». <https://github.com/kubernetes-sigs/metrics-server>. Version : metrics-server v0.9.0. Consulté le 23 octobre 2026.
- « Release v0.9.0 · kubernetes-sigs/metrics-server ». <https://github.com/kubernetes-sigs/metrics-server/releases/tag/v0.9.0>. Version : metrics-server v0.9.0. Consulté le 23 octobre 2026.
- « containerd : RELEASES.md ». <https://github.com/containerd/containerd/blob/main/RELEASES.md>. Version : containerd 2.3 et 2.4 (prise en charge de Kubernetes 1.37). Consulté le 23 octobre 2026.
- « kubernetes-sigs/cri-tools ». <https://github.com/kubernetes-sigs/cri-tools>. Version : crictl v1.35.0 (nœuds du lab). Consulté le 23 octobre 2026.

### Opérateur et chart du cours : cert-manager, podinfo

cert-manager v1.21 est officiellement pris en charge jusqu'à Kubernetes 1.36 ; aucune version publiée au 23 octobre 2026 ne liste encore la 1.37 (la 1.22 est attendue vers novembre 2026).

- « cert-manager ». <https://cert-manager.io/docs/>. Version : cert-manager v1.21. Consulté le 23 octobre 2026.
- « Helm ». <https://cert-manager.io/docs/installation/helm/>. Version : cert-manager v1.21.2. Consulté le 23 octobre 2026.
- « Supported Releases ». <https://cert-manager.io/docs/releases/>. Version : cert-manager v1.21 (Kubernetes 1.33 à 1.36). Consulté le 23 octobre 2026.
- « SelfSigned ». <https://cert-manager.io/docs/configuration/selfsigned/>. Version : cert-manager v1.21. Consulté le 23 octobre 2026.
- « Certificate resource ». <https://cert-manager.io/docs/usage/certificate/>. Version : cert-manager v1.21. Consulté le 23 octobre 2026.
- « API Reference ». <https://cert-manager.io/docs/reference/api-docs/>. Version : cert-manager v1.21, API cert-manager.io/v1. Consulté le 23 octobre 2026.
- « Release v1.21.2 · cert-manager/cert-manager ». <https://github.com/cert-manager/cert-manager/releases/tag/v1.21.2>. Version : cert-manager v1.21.2. Consulté le 23 octobre 2026.
- « stefanprodan/podinfo ». <https://github.com/stefanprodan/podinfo>. Version : podinfo 6.15.0. Consulté le 23 octobre 2026.
- « Release 6.15.0 · stefanprodan/podinfo ». <https://github.com/stefanprodan/podinfo/releases/tag/6.15.0>. Version : podinfo 6.15.0 (31 août 2026). Consulté le 23 octobre 2026.
- « podinfo/charts/podinfo at master · stefanprodan/podinfo ». <https://github.com/stefanprodan/podinfo/tree/master/charts/podinfo>. Version : chart podinfo 6.15.0. Consulté le 23 octobre 2026.

---
