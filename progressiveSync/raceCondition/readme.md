To reproduce the condition where applications are syncing out of order locally, after enabling progressive sync,
1. Make sure progressive sync is [enabled](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/#enabling-progressive-syncs)
2. Set the [jitter](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/#application-sync-timeout-jitter)  to 5s
3. Running locally on a mac, with the command:
  `CGO_FLAG=1 STATIC_BUILD=false DOCKER=podman ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS=true  ARGOCD_GPG_ENABLED=false ARGOCD_RECONCILIATION_JITTER=70 make start-local`
4. Use the yaml in raceCondition to create applicationset.
5. Applications should be created in the order -> wave0->wave1->wave2. Once all applications are created, edit the yaml of the deployment to be stuck - like in the [commit](https://github.com/ranakan19/argocd-example-apps/commit/1e25d719a5124381491cfd31686f9d0eb2c8e42d) - Make sure to use your own fork in the applicationset yaml as well for the change to take effect.
6. With the changes, wave0 applications would never turn Healthy so ideally wave1 and wave2 applications should not start progressing, but can see that applications in wave2 start progressing as well. With the jitter value so low, this can be consistently reproduced. By default the value of jitter is 60s, which makes it harder to reproduce in local dev setup.
